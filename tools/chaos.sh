#!/usr/bin/env bash
# 障害シナリオを起こす・元に戻すスクリプト
#
# 使い方:
#   ./tools/chaos.sh config-mistake   # シナリオ1: 決済タイムアウトを検証用の値(50ms)で上書き
#   ./tools/chaos.sh bad-release      # シナリオ2: バグ入りバージョン(1.4.0)をデプロイ
#   ./tools/chaos.sh db-throttle      # シナリオ3: DB の書き込み容量を最小にする
#   ./tools/chaos.sh reset            # すべて正常な状態に戻す
#
# 前提:
#   - AWS CLI にログイン済み（aws sts get-caller-identity が通ること）
#   - infra/ で terraform apply 済み
#
# シナリオ2と3は terraform 経由で変更します。
# 「デプロイの直後に障害が起きた」という記録を CloudTrail に残すためです。
#
# 注意:
#   - シナリオを切り替えるときは、必ず間に reset を挟んでください。
#     （bad-release のあとに db-throttle を実行すると、fault_mode が none に戻ってしまいます）
#   - infra/variables.tf の project を変えた場合は、下の PARAM も合わせて変えてください。

set -euo pipefail

cd "$(dirname "$0")/.."
PARAM="/ops-lab/payment/timeout_ms"
REGION="${AWS_REGION:-ap-northeast-1}"

case "${1:-}" in
  config-mistake)
    # 本番値 3000ms を、検証用の 50ms で上書きしてしまった、という想定
    aws ssm put-parameter --region "$REGION" --name "$PARAM" --value "50" --type String --overwrite
    echo "決済タイムアウトを 50ms に変更しました（30秒以内に反映されます）"
    ;;
  bad-release)
    terraform -chdir=infra apply -auto-approve -var="app_version=1.4.0" -var="fault_mode=coupon_bug"
    echo "バージョン 1.4.0（クーポン付き注文で落ちるバグ入り）をデプロイしました"
    ;;
  db-throttle)
    terraform -chdir=infra apply -auto-approve -var="table_write_capacity=1"
    echo "DB の書き込み容量を 1 にしました。load.py を --rate 4 で流してください（容量5のうちから流しておく）"
    echo "（DynamoDB には貯めておける余力があるので、詰まり始めるまで数分かかることがあります）"
    ;;
  reset)
    aws ssm put-parameter --region "$REGION" --name "$PARAM" --value "3000" --type String --overwrite
    terraform -chdir=infra apply -auto-approve
    echo "すべて正常な状態に戻しました"
    ;;
  *)
    echo "使い方: $0 {config-mistake|bad-release|db-throttle|reset}"
    exit 1
    ;;
esac
