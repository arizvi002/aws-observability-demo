output "instance_id" {
  value = aws_instance.windows.id
}

output "instance_public_ip" {
  value = aws_instance.windows.public_ip
}

output "sns_topic_arn" {
  value = aws_sns_topic.alarms.arn
}

output "dashboard_url" {
  value = "https://${var.region}.console.aws.amazon.com/cloudwatch/home?region=${var.region}#dashboards:name=${aws_cloudwatch_dashboard.main.dashboard_name}"
}
