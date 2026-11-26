# terraform apply のあとに表示される値
output "api_url" {
  description = "注文APIのURL（tools/load.py の --url に渡す）"
  value       = "${aws_apigatewayv2_stage.default.invoke_url}orders"
}

output "dashboard_url" {
  description = "CloudWatch ダッシュボードのURL"
  value       = "https://${var.region}.console.aws.amazon.com/cloudwatch/home?region=${var.region}#dashboards/dashboard/${aws_cloudwatch_dashboard.main.dashboard_name}"
}

output "alerts_topic_arn" {
  description = "アラームの通知先 SNS トピック（DevOps Agent や Slack をつなぐ）"
  value       = aws_sns_topic.alerts.arn
}

output "lambda_log_group" {
  description = "アプリのログの場所"
  value       = aws_cloudwatch_log_group.order_api.name
}
