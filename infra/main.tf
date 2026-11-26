# =====================================================================
# 注文API の本体（API Gateway → Lambda → DynamoDB、設定は SSM）
# すべて常時無料枠のあるサービスで構成している
# =====================================================================

locals {
  name = var.project
}

# ---- DB：注文テーブル -------------------------------------------------
# 障害シナリオ3で容量を絞れるよう、あえて「プロビジョンド（容量固定）」にしている
resource "aws_dynamodb_table" "orders" {
  name           = "${local.name}-orders"
  billing_mode   = "PROVISIONED"
  read_capacity  = 5
  write_capacity = var.table_write_capacity
  hash_key       = "order_id"

  attribute {
    name = "order_id"
    type = "S"
  }
}

# ---- 設定：決済タイムアウト値 -----------------------------------------
# 障害シナリオ1では CLI でこの値を書き換える。
# terraform apply で元に戻されないよう、値の変更は無視する設定にしている
resource "aws_ssm_parameter" "payment_timeout" {
  name        = "/${local.name}/payment/timeout_ms"
  description = "決済タイムアウト（ミリ秒）。本番値は 3000"
  type        = "String"
  value       = "3000"

  lifecycle {
    ignore_changes = [value]
  }
}

# ---- Lambda の実行ロール（必要最小限の権限だけ）------------------------
data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda" {
  name               = "${local.name}-order-api-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

# ログ出力の権限（AWS が用意している管理ポリシー）
resource "aws_iam_role_policy_attachment" "lambda_logs" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# 注文テーブルへの書き込みと、タイムアウト設定の読み取りだけを許可
data "aws_iam_policy_document" "lambda_app" {
  statement {
    actions   = ["dynamodb:PutItem"]
    resources = [aws_dynamodb_table.orders.arn]
  }
  statement {
    actions   = ["ssm:GetParameter"]
    resources = [aws_ssm_parameter.payment_timeout.arn]
  }
}

resource "aws_iam_role_policy" "lambda_app" {
  name   = "${local.name}-order-api-app"
  role   = aws_iam_role.lambda.id
  policy = data.aws_iam_policy_document.lambda_app.json
}

# ---- Lambda 関数 ------------------------------------------------------
data "archive_file" "order_api" {
  type        = "zip"
  source_dir  = "${path.module}/../app/order_api"
  output_path = "${path.module}/.build/order_api.zip"
  # キャッシュファイルを含めると、中身が同じでもコード更新が走り、余計なデプロイ記録が残るため除外
  excludes = ["__pycache__"]
}

# ログの保存期間を7日にする（放っておくと無期限で溜まるため、先に作っておく）
resource "aws_cloudwatch_log_group" "order_api" {
  name              = "/aws/lambda/${local.name}-order-api"
  retention_in_days = 7
}

resource "aws_lambda_function" "order_api" {
  function_name    = "${local.name}-order-api"
  role             = aws_iam_role.lambda.arn
  runtime          = "python3.12"
  handler          = "handler.lambda_handler"
  filename         = data.archive_file.order_api.output_path
  source_code_hash = data.archive_file.order_api.output_base64sha256
  memory_size      = 128
  timeout          = 10

  # リリースの説明。DevOps Agent がこの文言だけで原因を決めつけないかも検証ポイント
  description = "order-api v${var.app_version}"

  environment {
    variables = {
      TABLE_NAME    = aws_dynamodb_table.orders.name
      TIMEOUT_PARAM = aws_ssm_parameter.payment_timeout.name
      APP_VERSION   = var.app_version
      FAULT_MODE    = var.fault_mode
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.order_api,
    aws_iam_role_policy_attachment.lambda_logs,
  ]
}

# ---- API Gateway（HTTP API）-------------------------------------------
resource "aws_apigatewayv2_api" "http" {
  name          = "${local.name}-http-api"
  protocol_type = "HTTP"
}

resource "aws_apigatewayv2_integration" "order_api" {
  api_id                 = aws_apigatewayv2_api.http.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.order_api.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "post_orders" {
  api_id    = aws_apigatewayv2_api.http.id
  route_key = "POST /orders"
  target    = "integrations/${aws_apigatewayv2_integration.order_api.id}"
}

# API のアクセスログ（ステータスコードと応答時間を残して、調査に使う）
resource "aws_cloudwatch_log_group" "api_access" {
  name              = "/aws/apigateway/${local.name}-http-api"
  retention_in_days = 7
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.http.id
  name        = "$default"
  auto_deploy = true

  # 認証なしの公開 API なので、無料枠を守るため1秒あたりのリクエスト数に上限をかける
  # （シナリオ3で負荷をかけられる程度の値にしている）
  default_route_settings {
    throttling_rate_limit  = 10
    throttling_burst_limit = 20
  }

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api_access.arn
    format = jsonencode({
      requestId        = "$context.requestId"
      routeKey         = "$context.routeKey"
      status           = "$context.status"
      responseLatency  = "$context.responseLatency"
      integrationError = "$context.integrationErrorMessage"
      requestTime      = "$context.requestTime"
    })
  }
}

# API Gateway から Lambda を呼んでよい、という許可
resource "aws_lambda_permission" "apigw" {
  statement_id  = "AllowInvokeFromHttpApi"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.order_api.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.http.execution_arn}/*/POST/orders"
}
