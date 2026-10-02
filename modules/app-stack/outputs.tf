output "alb_dns_name" {
  description = "DNS del ALB."
  value       = aws_lb.app.dns_name
}

output "alb_zone_id" {
  description = "Hosted zone ID del ALB (para registros alias de Route 53)."
  value       = aws_lb.app.zone_id
}

output "alb_arn_suffix" {
  description = "Sufijo del ARN del ALB (dimensión LoadBalancer en CloudWatch)."
  value       = aws_lb.app.arn_suffix
}

output "target_group_arn_suffix" {
  description = "Sufijo del ARN del target group (dimensión TargetGroup en CloudWatch)."
  value       = aws_lb_target_group.app.arn_suffix
}

output "asg_name" {
  description = "Nombre del Auto Scaling Group (lo usa el runbook de failover)."
  value       = aws_autoscaling_group.app.name
}

output "app_security_group_id" {
  description = "Security group de las instancias (para abrir acceso a la base de datos)."
  value       = aws_security_group.app.id
}

output "region" {
  description = "Región donde se desplegó el stack."
  value       = data.aws_region.current.region
}

output "health_check_path" {
  description = "Ruta de salud expuesta por la aplicación."
  value       = "/health"
}
