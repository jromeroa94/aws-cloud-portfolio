# Módulo `app-stack`

Capa de aplicación web reutilizable: **ALB + Auto Scaling Group + AWS WAF**, idéntica en cualquier región. El proyecto 01 la instancia dos veces (primaria y DR) cambiando solo la capacidad.

## Qué incluye

| Componente | Detalle |
|---|---|
| ALB | HTTPS con política TLS 1.2/1.3 si hay certificado (HTTP → 301), `drop_invalid_header_fields`, access logs opcionales |
| AWS WAF | Reputación de IPs, Core Rule Set, Known Bad Inputs (incluye Log4Shell) y *rate limiting* por IP; logs con `Authorization` y `Cookie` redactados |
| ASG | Graviton (`t4g`), AMI Amazon Linux 2023 resuelta vía SSM, health checks del ALB, escalado por CPU, `instance_refresh` con rollback automático |
| Instancias | IMDSv2 obligatorio, EBS gp3 cifrado, sin SSH (SSM Session Manager), sin IP pública |
| Security groups | ALB → app solo en el puerto 8080; reglas como recursos individuales (`aws_vpc_security_group_*_rule`) |

## Uso

```hcl
module "app" {
  source = "../../modules/app-stack"

  name               = "portfolio-prod-primary"
  role               = "primary" # o "standby"
  vpc_id             = module.vpc.vpc_id
  public_subnet_ids  = module.vpc.public_subnet_ids
  private_subnet_ids = module.vpc.private_subnet_ids

  min_size         = 2
  max_size         = 6
  desired_capacity = 2

  certificate_arn = "arn:aws:acm:sa-east-1:123456789012:certificate/..."
}
```

`desired_capacity` está en `ignore_changes`: un runbook de failover puede escalar el ASG sin que el siguiente `terraform apply` lo revierta.

## Salidas

`alb_dns_name`, `alb_zone_id`, `alb_arn_suffix`, `target_group_arn_suffix`, `asg_name`, `app_security_group_id`, `region`, `health_check_path`.
