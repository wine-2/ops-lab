"""
注文APIに負荷をかけるスクリプト（標準ライブラリだけで動きます）

使い方:
    python tools/load.py --url https://xxxx.execute-api.ap-northeast-1.amazonaws.com/orders --minutes 5

    --rate      1秒あたりの注文数（既定 2）
    --coupon    クーポン付き注文の割合（既定 0.3 = 30%）

注意:
    - 無料枠を使い切らないよう、既定値は控えめにしています（5分で約600リクエスト）
    - Ctrl+C でいつでも止められます
"""

import argparse
import json
import random
import threading
import time
import urllib.error
import urllib.request
from collections import Counter
from concurrent.futures import ThreadPoolExecutor


def make_order(coupon_ratio):
    """ランダムな注文を作る。一部にクーポンを付ける"""
    order = {"items": [{"price": random.choice([300, 500, 1200]), "qty": random.randint(1, 3)}]}
    if random.random() < coupon_ratio:
        order["coupon"] = {"code": "WELCOME", "discount": 100}
    return order


def send(url, order):
    req = urllib.request.Request(
        url, data=json.dumps(order).encode(), headers={"Content-Type": "application/json"}, method="POST"
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as res:
            return res.status
    except urllib.error.HTTPError as e:
        return e.code
    except Exception:
        return "network_error"


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--url", required=True, help="terraform output の api_url（末尾 /orders 付き）")
    p.add_argument("--minutes", type=float, default=5)
    p.add_argument("--rate", type=float, default=2)
    p.add_argument("--coupon", type=float, default=0.3)
    args = p.parse_args()

    end = time.time() + args.minutes * 60
    counts = Counter()
    lock = threading.Lock()

    def record(future):
        # 応答が返ってきた順に集計する（複数スレッドから呼ばれるのでロックする）
        with lock:
            counts[future.result()] += 1

    # 1件ずつ順番に送ると応答待ちで rate が出ないため、並列で送る
    pool = ThreadPoolExecutor(max_workers=16)
    last_print = time.time()
    try:
        while time.time() < end:
            pool.submit(send, args.url, make_order(args.coupon)).add_done_callback(record)
            time.sleep(1 / args.rate)
            if time.time() - last_print > 10:
                with lock:
                    print(time.strftime("%H:%M:%S"), dict(counts))
                last_print = time.time()
    except KeyboardInterrupt:
        pass
    pool.shutdown(wait=True)
    print("結果:", dict(counts))


if __name__ == "__main__":
    main()
