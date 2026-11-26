"""
注文APIのテスト（moto で DynamoDB と SSM を模擬して、AWS につながずに動かす）

実行方法:
    pip install pytest "moto[dynamodb,ssm]" boto3
    cd app && python -m pytest -q
"""

import importlib
import json
import os
import sys

import boto3
import pytest
from moto import mock_aws

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "order_api"))

TABLE = "ops-lab-orders"
PARAM = "/ops-lab/payment/timeout_ms"


class Ctx:
    aws_request_id = "test-request"


def load_handler(fault_mode="none", timeout_ms="3000", pay_min=10, pay_max=20):
    """環境変数をセットしてから handler を読み込み直す（設定はモジュール読み込み時に決まるため）"""
    os.environ.update({
        "AWS_DEFAULT_REGION": "ap-northeast-1",
        "TABLE_NAME": TABLE,
        "TIMEOUT_PARAM": PARAM,
        "FAULT_MODE": fault_mode,
        "PAYMENT_MIN_MS": str(pay_min),
        "PAYMENT_MAX_MS": str(pay_max),
        "CONFIG_CACHE_SEC": "0",
    })
    boto3.resource("dynamodb").create_table(
        TableName=TABLE,
        KeySchema=[{"AttributeName": "order_id", "KeyType": "HASH"}],
        AttributeDefinitions=[{"AttributeName": "order_id", "AttributeType": "S"}],
        BillingMode="PAY_PER_REQUEST",
    )
    boto3.client("ssm").put_parameter(Name=PARAM, Value=timeout_ms, Type="String", Overwrite=True)
    import handler
    return importlib.reload(handler)


def event(body):
    return {"body": json.dumps(body)}


@mock_aws
def test_正常な注文は201で保存される():
    h = load_handler()
    res = h.lambda_handler(event({"items": [{"price": 500, "qty": 2}]}), Ctx())
    assert res["statusCode"] == 201
    body = json.loads(res["body"])
    assert body["total"] == 1000
    item = boto3.resource("dynamodb").Table(TABLE).get_item(Key={"order_id": body["order_id"]})
    assert item["Item"]["total"] == 1000


@mock_aws
def test_Base64で届いた本文も読める():
    # Content-Type なしで送ると HTTP API は本文を Base64 にして渡してくる（実環境で見つけた不具合）
    import base64 as b64
    h = load_handler()
    body = b64.b64encode(json.dumps({"items": [{"price": 300}]}).encode()).decode()
    res = h.lambda_handler({"body": body, "isBase64Encoded": True}, Ctx())
    assert res["statusCode"] == 201


@mock_aws
def test_itemsが無いと400():
    h = load_handler()
    res = h.lambda_handler(event({}), Ctx())
    assert res["statusCode"] == 400


@mock_aws
def test_おかしな入力は例外にせず400():
    # 配列や価格なしの注文で Lambda の例外アラームが鳴らないこと
    h = load_handler()
    for body in ([], {"items": "x"}, {"items": [{"qty": 1}]}, {"items": [{"price": "abc"}]}):
        assert h.lambda_handler(event(body), Ctx())["statusCode"] == 400


@mock_aws
def test_タイムアウト設定が小さすぎると504():
    # 決済に10〜20ms かかるのに、タイムアウトを1msにした「設定ミス」シナリオ
    h = load_handler(timeout_ms="1")
    res = h.lambda_handler(event({"items": [{"price": 100}]}), Ctx())
    assert res["statusCode"] == 504


@mock_aws
def test_通常版はクーポン付き注文も通る():
    h = load_handler()
    res = h.lambda_handler(event({"items": [{"price": 1000}], "coupon": {"discount": 200}}), Ctx())
    assert res["statusCode"] == 201
    assert json.loads(res["body"])["total"] == 800


@mock_aws
def test_バグ入りリリースはクーポン付き注文で例外になる():
    h = load_handler(fault_mode="coupon_bug")
    with pytest.raises(KeyError):
        h.lambda_handler(event({"items": [{"price": 1000}], "coupon": {"discount": 200}}), Ctx())


@mock_aws
def test_バグ入りリリースでもクーポン無しなら通る():
    # 「一部の注文だけ失敗する」ので、原因の切り分けが少し難しくなる
    h = load_handler(fault_mode="coupon_bug")
    res = h.lambda_handler(event({"items": [{"price": 1000}]}), Ctx())
    assert res["statusCode"] == 201


@mock_aws
def test_SSMが読めなくても既定値で動き続ける():
    h = load_handler()
    boto3.client("ssm").delete_parameter(Name=PARAM)
    res = h.lambda_handler(event({"items": [{"price": 100}]}), Ctx())
    assert res["statusCode"] == 201
