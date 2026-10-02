output "primary_alb_dns" {
  description = "Endpoint de la región primaria."
  value       = module.app_primary.alb_dns_name
}

output "dr_alb_dns" {
  description = "Endpoint de la región de DR."
  value       = module.app_dr.alb_dns_name
}

output "app_url" {
  description = "URL pública con failover de Route 53 (si se configuró DNS)."
  value       = local.dns_enable ? "https://${var.app_fqdn}" : null
}

output "global_cluster_id" {
  description = "Identificador del Aurora Global Database (lo usa el runbook)."
  value       = aws_rds_global_cluster.this.id
}

output "primary_cluster_arn" {
  description = "ARN del cluster primario."
  value       = aws_rds_cluster.primary.arn
}

output "dr_cluster_arn" {
  description = "ARN del cluster de DR (destino de failover-global-cluster)."
  value       = aws_rds_cluster.dr.arn
}

output "db_secret_arn" {
  description = "Secreto con las credenciales maestras (replicado a DR)."
  value       = aws_secretsmanager_secret.db_master.arn
}

output "asg_names" {
  description = "ASGs por región (el runbook escala el de DR)."
  value = {
    primary = module.app_primary.asg_name
    dr      = module.app_dr.asg_name
  }
}

output "failover_commands" {
  description = "Comandos de failover listos para copiar (ver runbooks/failover.md)."
  value       = <<-EOT
    # 1) Promover Aurora en DR (failover no planificado, acepta pérdida de datos <= lag actual)
    aws rds failover-global-cluster --region ${var.dr_region} \
      --global-cluster-identifier ${aws_rds_global_cluster.this.id} \
      --target-db-cluster-identifier ${aws_rds_cluster.dr.arn} \
      --allow-data-loss

    # 2) Escalar el cómputo de DR a capacidad de producción
    aws autoscaling update-auto-scaling-group --region ${var.dr_region} \
      --auto-scaling-group-name ${module.app_dr.asg_name} \
      --min-size ${var.primary_capacity.min} --desired-capacity ${var.primary_capacity.desired}
  EOT
}
