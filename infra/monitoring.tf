# =====================================================================
# 監視：アラーム・通知・ダッシュボード・保存クエリ・予算
# アラームは無料枠（10個）に収まる4個にしている
# =====================================================================

# ---- 通知先（SNS トピック）--------------------------------------------
# DevOps Agent の Webhook や Slack 連携も、このトピックにつなぐ想定
resource "aws_sns_topic" "alerts" {
  name = "${local.name}-alerts"
}

resource "aws_sns_topic_subscription" "email" {
  count     = var.alert_email == "" ? 0 : 1
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# ---- ログから「注文失敗の件数」を数えるメトリクス -----------------------
# アプリは JSON ログを出すので、level が ERROR の行を数える
resource "aws_cloudwatch_log_metric_filter" "order_errors" {
  name           = "${local.name}-order-errors"
  log_group_name = aws_cloudwatch_log_group.order_api.name
  pattern        = "{ $.level = \"ERROR\" }"

  metric_transformation {
    name          = "OrderErrors"
    namespace     = "OpsLab"
    value         = "1"
    default_value = "0"
  }
}

# ---- アラーム1：API の 5xx エラー（お客さんから見た異常）----------------
resource "aws_cloudwatch_metric_alarm" "api_5xx" {
  alarm_name          = "${local.name}-api-5xx"
  alarm_description   = "注文APIの5xxエラーが1分間に5件以上。注文できないお客さんが出ている"
  namespace           = "AWS/ApiGateway"
  metric_name         = "5xx"
  dimensions          = { ApiId = aws_apigatewayv2_api.http.id }
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 5
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
}

# ---- アラーム2：Lambda の例外（想定外のバグ）---------------------------
resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  alarm_name          = "${local.name}-lambda-errors"
  alarm_description   = "注文APIのLambdaで想定外の例外が1分間に3件以上。バグの可能性"
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  dimensions          = { FunctionName = aws_lambda_function.order_api.function_name }
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 3
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
}

# ---- アラーム3：DB の書き込み詰まり -----------------------------------
resource "aws_cloudwatch_metric_alarm" "dynamodb_throttle" {
  alarm_name          = "${local.name}-dynamodb-write-throttle"
  alarm_description   = "注文テーブルへの書き込みが容量不足で弾かれている"
  namespace           = "AWS/DynamoDB"
  metric_name         = "WriteThrottleEvents"
  dimensions          = { TableName = aws_dynamodb_table.orders.name }
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
}

# ---- アラーム4：注文失敗の件数（ログ由来）------------------------------
resource "aws_cloudwatch_metric_alarm" "order_errors" {
  alarm_name          = "${local.name}-order-errors"
  alarm_description   = "注文処理のエラーログが1分間に5件以上"
  namespace           = "OpsLab"
  metric_name         = "OrderErrors"
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 5
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]

  depends_on = [aws_cloudwatch_log_metric_filter.order_errors]
}

# ---- Logs Insights の保存クエリ（人も DevOps Agent も使える）-----------
resource "aws_cloudwatch_query_definition" "errors_by_type" {
  name            = "${local.name}/errors-by-type"
  log_group_names = [aws_cloudwatch_log_group.order_api.name]
  query_string    = <<-EOT
    fields @timestamp, error_type, app_version, detail
    | filter level = "ERROR"
    | stats count(*) as errors by error_type, app_version, bin(1m)
    | sort errors desc
  EOT
}

resource "aws_cloudwatch_query_definition" "config_changes" {
  name            = "${local.name}/timeout-config-changes"
  log_group_names = [aws_cloudwatch_log_group.order_api.name]
  query_string    = <<-EOT
    fields @timestamp, timeout_ms, previous_timeout_ms, app_version
    | filter message = "payment timeout config loaded"
    | sort @timestamp desc
  EOT
}

# ---- ダッシュボード ---------------------------------------------------
resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = "${local.name}-overview"
  dashboard_body = jsonencode({
    widgets = [
      {
        type = "metric", x = 0, y = 0, width = 12, height = 6
        properties = {
          title  = "注文API：リクエスト数と5xx"
          region = var.region
          stat   = "Sum"
          period = 60
          metrics = [
            ["AWS/ApiGateway", "Count", "ApiId", aws_apigatewayv2_api.http.id],
            ["AWS/ApiGateway", "5xx", "ApiId", aws_apigatewayv2_api.http.id],
          ]
        }
      },
      {
        type = "metric", x = 12, y = 0, width = 12, height = 6
        properties = {
          title  = "Lambda：処理時間(p95)と例外"
          region = var.region
          period = 60
          metrics = [
            ["AWS/Lambda", "Duration", "FunctionName", aws_lambda_function.order_api.function_name, { stat = "p95" }],
            ["AWS/Lambda", "Errors", "FunctionName", aws_lambda_function.order_api.function_name, { stat = "Sum", yAxis = "right" }],
          ]
        }
      },
      {
        type = "metric", x = 0, y = 6, width = 12, height = 6
        properties = {
          title  = "DynamoDB：書き込み消費量と詰まり"
          region = var.region
          stat   = "Sum"
          period = 60
          metrics = [
            ["AWS/DynamoDB", "ConsumedWriteCapacityUnits", "TableName", aws_dynamodb_table.orders.name],
            ["AWS/DynamoDB", "WriteThrottleEvents", "TableName", aws_dynamodb_table.orders.name, { yAxis = "right" }],
          ]
        }
      },
      {
        type = "metric", x = 12, y = 6, width = 12, height = 6
        properties = {
          title   = "注文失敗の件数（ログから集計）"
          region  = var.region
          stat    = "Sum"
          period  = 60
          metrics = [["OpsLab", "OrderErrors"]]
        }
      },
      {
        type = "log", x = 0, y = 12, width = 24, height = 6
        properties = {
          title  = "直近のエラー（種類・バージョン別）"
          region = var.region
          query  = "SOURCE '${aws_cloudwatch_log_group.order_api.name}' | fields @timestamp, error_type, app_version, detail | filter level = \"ERROR\" | sort @timestamp desc | limit 20"
          view   = "table"
        }
      },
    ]
  })
}

# ---- 予算アラート（使いすぎに早めに気づくため）-------------------------
resource "aws_budgets_budget" "monthly" {
  count        = var.alert_email == "" ? 0 : 1
  name         = "${local.name}-monthly"
  budget_type  = "COST"
  limit_amount = var.budget_limit_usd
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  # 無料プランはクレジットで相殺されて $0 に見えるので、クレジットを差し引く前の金額で判定する
  cost_types {
    include_credit = false
  }

  # 実際の利用額が予算の80%を超えたとき
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.alert_email]
  }

  # 月末の予測額が予算を超えそうなとき（使い始めは予測が出ないこともある）
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.alert_email]
  }
}
