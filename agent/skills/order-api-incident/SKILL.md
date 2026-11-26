---
name: order-api-incident
description: ops-lab の注文API（API Gateway / Lambda / DynamoDB）でアラームが鳴ったときの調査手順。5xx の増加、Lambda の例外、DynamoDB の書き込み詰まり、注文失敗ログの増加の調査で使う。
---

# 注文API 障害調査の手順

アラーム `ops-lab-*` が ALARM になったときに、この順番で調べる。
各ステップで分かった事実は、時刻と値をメモしながら進める。

## ステップ1：何が起きているかを確定する

- どのアラームが、いつ ALARM になったかを確認する。
- API Gateway のメトリクス `Count` と `5xx`（次元 ApiId）で、失敗の割合と始まった時刻を出す。
- 失敗が「全部の注文」か「一部の注文」かを区別する。一部だけなら、入力内容（クーポンの有無など）に偏りがないか後で確認する。

## ステップ2：アプリのログでエラーの種類を分ける

ロググループ `/aws/lambda/ops-lab-order-api` を Logs Insights で調べる。保存クエリ `ops-lab/errors-by-type` を使ってよい。

```
fields @timestamp, error_type, app_version, detail
| filter level = "ERROR"
| stats count(*) as errors by error_type, app_version, bin(1m)
```

error_type ごとの意味は次のとおり。

| error_type | 意味 | 次に見るところ |
|---|---|---|
| PaymentTimeoutError | 決済がタイムアウト時間内に終わらない | ステップ3（設定） |
| ProvisionedThroughputExceededException など | DB の書き込みが容量不足で弾かれた | ステップ5（DB） |
| KeyError など Python の例外名 | アプリのバグ | ステップ4（リリース） |

## ステップ3：設定の変更を確認する

- SSM パラメータ `/ops-lab/payment/timeout_ms` の現在の値と、変更履歴（パラメータの履歴、CloudTrail の PutParameter）を確認する。本番の正しい値は 3000。
- 保存クエリ `ops-lab/timeout-config-changes` で、アプリが新しい値を読み込んだ時刻を確認する。
- 値が小さくなった時刻と、エラーが増え始めた時刻が合っているかを比べる。
- アプリは SSM の値を30秒キャッシュして読み直す。値を戻せば30秒以内に反映され、Lambda の再デプロイは要らない。

## ステップ4：リリースの変更を確認する

- Lambda 関数 `ops-lab-order-api` の環境変数 `APP_VERSION` と `FAULT_MODE`、最終更新時刻を確認する。CloudTrail の UpdateFunctionConfiguration と UpdateFunctionCode も見る。
- この Agent Space のロールでは lambda:GetFunction が拒否されることがある。そのときは CloudTrail の UpdateFunctionConfiguration の requestParameters から環境変数の値を読む。
- `FAULT_MODE` が `none` 以外なら、バグ入りの設定でリリースされている。
- コードが変わったかどうかは、CodeSha256 を変更の前後で比べて判断する。同じなら変わったのは設定だけで、コードのロールバックは要らない。
- 説明文（description）の内容だけで判断しない。エラーの起きた注文の特徴（クーポンの有無）と、例外の内容を突き合わせる。

## ステップ5：DB の状態を確認する

- テーブル `ops-lab-orders` の書き込み容量（WriteCapacityUnits）と、その変更履歴（CloudTrail の UpdateTable）を確認する。通常は 5。
- メトリクス `ConsumedWriteCapacityUnits` と `WriteThrottleEvents` で、容量に対してどれだけ書き込みが来ているかを見る。

## ステップ6：結論を出す前のチェック

- 原因の候補が複数あるときは、それぞれ「エラーが始まった時刻と変更の時刻が合うか」で絞り込む。
- 原因が2つ以上重なっていないかを確かめる。error_type や HTTP ステータス（500 と 504 など）ごとに始まった時刻を分け、それぞれに対応する変更があるかを見る。重なっているなら、片方だけ戻しても直らないと書く。
- 「ロールバックで直るか」を必ず判断する。原因が SSM や DB の設定にあるなら、ロールバックでは直らない。
- 「今も続いているか」は、アラームの現在の状態と最新ログの時刻で判断する。直近数分のメトリクスの空白は、回復の証拠にしない。

## 報告フォーマット

次の JSON を最初に出し、そのあとに日本語の説明を続ける。値が分からない項目は null にして、推測で埋めない。

```json
{
  "root_cause": "根本原因を1文で",
  "cause_layer": "config | application | database | multiple | unknown",
  "still_ongoing": true,
  "started_at": "エラーが増え始めた時刻（ISO 8601）",
  "evidence": [
    {"source": "ログ・メトリクス・変更履歴の名前", "time": "時刻", "value": "見つけた値"}
  ],
  "rollback_fixes_it": true,
  "first_response": "一次対応案を1文で",
  "permanent_fix": "再発防止策を1文で"
}
```

### 出力例（設定ミスの場合）

```json
{
  "root_cause": "SSM パラメータ /ops-lab/payment/timeout_ms が 3000 から 50 に変更され、決済がタイムアウトしている",
  "cause_layer": "config",
  "still_ongoing": true,
  "started_at": "2026-12-01T10:04:00+09:00",
  "evidence": [
    {"source": "CloudTrail PutParameter", "time": "2026-12-01T10:03:41+09:00", "value": "/ops-lab/payment/timeout_ms = 50"},
    {"source": "Logs Insights errors-by-type", "time": "2026-12-01T10:04:00+09:00", "value": "PaymentTimeoutError 42件/分"}
  ],
  "rollback_fixes_it": false,
  "first_response": "SSM パラメータを本番値 3000 に戻す（人の承認後）",
  "permanent_fix": "本番パラメータの変更に承認フローを入れ、検証用の値と名前空間を分ける"
}
```
