"""
注文API（デモ用）

ネットショップの「注文を受け付ける」APIを模したLambda関数です。
DevOps Agent に調査させるため、次の仕掛けを入れています。

- 決済タイムアウト値を SSM パラメータストアから読む
  （設定ミスで値が小さくなると、決済がタイムアウトして注文が失敗する）
- FAULT_MODE 環境変数で「バグ入りリリース」を再現できる
- ログはすべて JSON 1行形式で出す（Logs Insights で集計しやすくするため）

本番の決済サービスは呼ばず、待ち時間をランダムに発生させて「外部決済」を模擬しています。
"""

import json
import os
import random
import time
import uuid
from datetime import datetime, timezone

import boto3
from botocore.config import Config
from botocore.exceptions import ClientError

# ---- 設定（環境変数）---------------------------------------------------
TABLE_NAME = os.environ.get("TABLE_NAME", "ops-lab-orders")
TIMEOUT_PARAM = os.environ.get("TIMEOUT_PARAM", "/ops-lab/payment/timeout_ms")
APP_VERSION = os.environ.get("APP_VERSION", "1.0.0")
# none: 正常 / coupon_bug: クーポン付き注文で落ちるバグ入りリリース
FAULT_MODE = os.environ.get("FAULT_MODE", "none")
# 外部決済の応答時間（ミリ秒）の範囲。デモ用の模擬値
PAYMENT_MIN_MS = int(os.environ.get("PAYMENT_MIN_MS", "80"))
PAYMENT_MAX_MS = int(os.environ.get("PAYMENT_MAX_MS", "400"))
# SSM の値をキャッシュする秒数（毎回読むと遅く・高くなるため）
CONFIG_CACHE_SEC = int(os.environ.get("CONFIG_CACHE_SEC", "30"))
DEFAULT_TIMEOUT_MS = 3000

# boto3 クライアントは関数の外で作り、ウォームスタート時に使い回す
# DB の自動リトライは2回までにする。多すぎると容量不足のときに Lambda 自体がタイムアウトし、
# 「DB の詰まり（503）」と「アプリのバグ（500）」の区別がつかなくなるため
_dynamodb = boto3.resource("dynamodb", config=Config(retries={"mode": "standard", "max_attempts": 2}))
_ssm = boto3.client("ssm")

_config_cache = {"value": None, "loaded_at": 0.0}


class PaymentTimeoutError(Exception):
    """決済が設定したタイムアウト時間内に終わらなかったときのエラー"""


def log(level, message, **fields):
    """JSON 1行でログを出す。Logs Insights で `fields level, error_type` のように絞り込める"""
    record = {
        "ts": datetime.now(timezone.utc).isoformat(),
        "level": level,
        "message": message,
        "app_version": APP_VERSION,
        **fields,
    }
    print(json.dumps(record, ensure_ascii=False))


def get_payment_timeout_ms():
    """決済タイムアウト値（ミリ秒）を SSM から取得する。失敗時は既定値で動き続ける"""
    now = time.time()
    if _config_cache["value"] is not None and now - _config_cache["loaded_at"] < CONFIG_CACHE_SEC:
        return _config_cache["value"]
    try:
        resp = _ssm.get_parameter(Name=TIMEOUT_PARAM)
        value = int(resp["Parameter"]["Value"])
        if value != _config_cache["value"]:
            # 値が変わった瞬間をログに残す。調査の手がかりになる
            log("INFO", "payment timeout config loaded", timeout_ms=value,
                previous_timeout_ms=_config_cache["value"], param=TIMEOUT_PARAM)
    except (ClientError, ValueError, KeyError) as e:
        log("WARN", "failed to load timeout config, using default",
            error_type=type(e).__name__, default_timeout_ms=DEFAULT_TIMEOUT_MS)
        value = DEFAULT_TIMEOUT_MS
    _config_cache["value"] = value
    _config_cache["loaded_at"] = now
    return value


def call_payment(amount, timeout_ms):
    """外部決済の呼び出しを模擬する。応答時間がタイムアウトを超えたら例外"""
    latency_ms = random.randint(PAYMENT_MIN_MS, PAYMENT_MAX_MS)
    if latency_ms > timeout_ms:
        # 実際の HTTP クライアントと同じく、タイムアウト時間だけ待ってから諦める
        time.sleep(timeout_ms / 1000)
        raise PaymentTimeoutError(f"payment timed out after {timeout_ms}ms (needed {latency_ms}ms)")
    time.sleep(latency_ms / 1000)
    return {"payment_id": str(uuid.uuid4()), "latency_ms": latency_ms, "amount": amount}


def calc_total(order):
    """合計金額を計算する。FAULT_MODE=coupon_bug のときだけ、クーポン付き注文で落ちる"""
    items = order.get("items", [])
    total = sum(int(i["price"]) * int(i.get("qty", 1)) for i in items)
    coupon = order.get("coupon")
    if coupon:
        if FAULT_MODE == "coupon_bug":
            # わざと仕込んだバグ：存在しないキーを参照して KeyError になる
            total -= coupon["discount_amount"]
        else:
            total -= int(coupon.get("discount", 0))
    return max(total, 0)


def is_valid_order(order):
    """注文の形をチェックする。おかしな入力で例外を出し、誤ってアラームを鳴らさないため"""
    if not isinstance(order, dict):
        return False
    items = order.get("items")
    if not isinstance(items, list) or not items:
        return False
    for i in items:
        if not isinstance(i, dict):
            return False
        try:
            if int(i["price"]) < 0 or int(i.get("qty", 1)) < 1:
                return False
        except (KeyError, ValueError, TypeError):
            return False
    coupon = order.get("coupon")
    if coupon is not None and not isinstance(coupon, dict):
        return False
    return True


def response(status, body):
    return {
        "statusCode": status,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body, ensure_ascii=False),
    }


def lambda_handler(event, context):
    request_id = getattr(context, "aws_request_id", str(uuid.uuid4()))
    started = time.time()

    # ---- 入力チェック -------------------------------------------------
    try:
        order = json.loads(event.get("body") or "{}")
        if not is_valid_order(order):
            return response(400, {"error": "invalid order"})
    except json.JSONDecodeError:
        return response(400, {"error": "invalid json"})

    order_id = str(uuid.uuid4())
    try:
        total = calc_total(order)
        timeout_ms = get_payment_timeout_ms()
        payment = call_payment(total, timeout_ms)

        # ---- 注文を保存 ---------------------------------------------------
        _dynamodb.Table(TABLE_NAME).put_item(Item={
            "order_id": order_id,
            "created_at": datetime.now(timezone.utc).isoformat(),
            "total": total,
            "payment_id": payment["payment_id"],
            "app_version": APP_VERSION,
        })

        elapsed = int((time.time() - started) * 1000)
        log("INFO", "order accepted", request_id=request_id, order_id=order_id,
            total=total, payment_latency_ms=payment["latency_ms"], elapsed_ms=elapsed)
        return response(201, {"order_id": order_id, "total": total})

    except PaymentTimeoutError as e:
        log("ERROR", "payment timeout", request_id=request_id, order_id=order_id,
            error_type="PaymentTimeoutError", detail=str(e), timeout_ms=_config_cache["value"])
        return response(504, {"error": "payment timeout", "order_id": order_id})

    except ClientError as e:
        code = e.response.get("Error", {}).get("Code", "Unknown")
        log("ERROR", "database error", request_id=request_id, order_id=order_id,
            error_type=code, detail=str(e))
        return response(503, {"error": "database unavailable", "order_id": order_id})

    except Exception as e:  # 想定外のエラー（バグ）はここに来る
        log("ERROR", "unhandled error", request_id=request_id, order_id=order_id,
            error_type=type(e).__name__, detail=str(e), fault_mode=FAULT_MODE)
        # Lambda の Errors メトリクスにも載せるため、あえて例外を投げ直す
        raise
