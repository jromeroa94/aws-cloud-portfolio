output "dashboard_url" {
  description = "Dashboard de CloudWatch del servicio."
  value       = "https://${var.region}.console.aws.amazon.com/cloudwatch/home?region=${var.region}#dashboards/dashboard/${aws_cloudwatch_dashboard.service.dashboard_name}"
}

output "slo_alarms" {
  description = "Alarmas compuestas de consumo del presupuesto de error."
  value       = { for k, a in aws_cloudwatch_composite_alarm.slo_burn : k => a.alarm_name }
}

output "error_budget_minutes_per_30d" {
  description = "Minutos de indisponibilidad total que permite el SLO en 30 días."
  value       = floor((1 - var.availability_slo) * 30 * 24 * 60)
}

output "opensearch_endpoint" {
  description = "Endpoint de OpenSearch (si está habilitado)."
  value       = local.os_enabled ? aws_opensearch_domain.logs[0].endpoint : null
}

output "opensearch_dashboards_url" {
  description = "OpenSearch Dashboards (Kibana) accesible desde la VPC."
  value       = local.os_enabled ? "https://${aws_opensearch_domain.logs[0].dashboard_endpoint}" : null
}
