locals {
  prefix     = "${var.name}-${var.environment}"
  dns_enable = var.route53_zone_id != null && var.app_fqdn != null
}

# =============================================================================
# Red: una VPC por región (módulo compartido)
# =============================================================================
module "vpc_primary" {
  source    = "../../modules/vpc"
  providers = { aws = aws.primary }

  name             = "${local.prefix}-primary"
  cidr_block       = var.primary_vpc_cidr
  az_count         = 3
  nat_gateway_mode = "per_az"
}

module "vpc_dr" {
  source    = "../../modules/vpc"
  providers = { aws = aws.dr }

  name       = "${local.prefix}-dr"
  cidr_block = var.dr_vpc_cidr
  az_count   = 3
  # Warm standby: una sola NAT mientras la región está en espera. En un failover
  # prolongado se cambia a "per_az" con un apply.
  nat_gateway_mode = "single"
}

# =============================================================================
# Cómputo: mismo módulo en ambas regiones, distinta capacidad
# =============================================================================
module "app_primary" {
  source    = "../../modules/app-stack"
  providers = { aws = aws.primary }

  name               = "${local.prefix}-primary"
  role               = "primary"
  vpc_id             = module.vpc_primary.vpc_id
  public_subnet_ids  = module.vpc_primary.public_subnet_ids
  private_subnet_ids = module.vpc_primary.private_subnet_ids
  instance_type      = var.instance_type

  min_size         = var.primary_capacity.min
  max_size         = var.primary_capacity.max
  desired_capacity = var.primary_capacity.desired

  certificate_arn     = var.certificate_arns.primary
  deletion_protection = var.deletion_protection
}

module "app_dr" {
  source    = "../../modules/app-stack"
  providers = { aws = aws.dr }

  name               = "${local.prefix}-dr"
  role               = "standby"
  vpc_id             = module.vpc_dr.vpc_id
  public_subnet_ids  = module.vpc_dr.public_subnet_ids
  private_subnet_ids = module.vpc_dr.private_subnet_ids
  instance_type      = var.instance_type

  min_size         = var.dr_capacity.min
  max_size         = var.dr_capacity.max
  desired_capacity = var.dr_capacity.desired

  certificate_arn     = var.certificate_arns.dr
  deletion_protection = var.deletion_protection
}

# =============================================================================
# Datos: Aurora PostgreSQL Global Database
#   - Replicación a nivel de almacenamiento, lag típico < 1 s  -> RPO < 1 min
#   - Failover gestionado a la región secundaria en minutos   -> RTO < 15 min
# =============================================================================
data "aws_caller_identity" "current" {
  provider = aws.primary
}

# Política explícita: administración por la cuenta; RDS y Secrets Manager usan la
# clave en nombre de los principales autorizados por IAM (kms:ViaService).
data "aws_iam_policy_document" "db_key" {
  #checkov:skip=CKV_AWS_111:Política de clave KMS: Resource "*" se refiere a la propia clave.
  #checkov:skip=CKV_AWS_356:Política de clave KMS: Resource "*" se refiere a la propia clave.
  #checkov:skip=CKV_AWS_109:Política de clave KMS: administración delegada en IAM de la cuenta.
  provider = aws.primary

  statement {
    sid       = "AccountAdministration"
    actions   = ["kms:*"]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
  }
}

resource "aws_kms_key" "db_primary" {
  provider = aws.primary
  policy   = data.aws_iam_policy_document.db_key.json

  description             = "${local.prefix} Aurora (primary)"
  enable_key_rotation     = true
  deletion_window_in_days = 30
}

resource "aws_kms_key" "db_dr" {
  provider = aws.dr
  policy   = data.aws_iam_policy_document.db_key.json

  description             = "${local.prefix} Aurora (dr)"
  enable_key_rotation     = true
  deletion_window_in_days = 30
}

resource "aws_rds_global_cluster" "this" {
  provider = aws.primary

  global_cluster_identifier = "${local.prefix}-global"
  engine                    = "aurora-postgresql"
  engine_version            = var.db_engine_version
  database_name             = "app"
  storage_encrypted         = true
  deletion_protection       = var.deletion_protection
}

# --- Contraseña maestra efímera: nunca se escribe en el estado de Terraform ---
ephemeral "random_password" "db_master" {
  length           = 32
  special          = true
  override_special = "!#$%^&*()-_=+[]{}<>:?"
}

resource "aws_secretsmanager_secret" "db_master" {
  #checkov:skip=CKV2_AWS_57:La rotación se hace con db_password_version (write-only); la app usa autenticación IAM.
  provider = aws.primary

  name_prefix = "${local.prefix}/aurora/master-"
  description = "Credenciales maestras de Aurora (replicadas a la región de DR)"
  kms_key_id  = aws_kms_key.db_primary.arn

  # La app en DR lee el secreto en su propia región, sin depender de la primaria.
  replica {
    region     = var.dr_region
    kms_key_id = aws_kms_key.db_dr.arn
  }
}

resource "aws_secretsmanager_secret_version" "db_master" {
  provider = aws.primary

  secret_id = aws_secretsmanager_secret.db_master.id
  secret_string_wo = jsonencode({
    username = "app_admin"
    password = ephemeral.random_password.db_master.result
  })
  secret_string_wo_version = var.db_password_version
}

# --- Red de la base de datos -------------------------------------------------
resource "aws_db_subnet_group" "primary" {
  provider = aws.primary

  name_prefix = "${local.prefix}-primary-"
  subnet_ids  = module.vpc_primary.data_subnet_ids
}

resource "aws_db_subnet_group" "dr" {
  provider = aws.dr

  name_prefix = "${local.prefix}-dr-"
  subnet_ids  = module.vpc_dr.data_subnet_ids
}

resource "aws_security_group" "db_primary" {
  provider = aws.primary

  name_prefix = "${local.prefix}-db-"
  description = "Aurora: solo desde la app"
  vpc_id      = module.vpc_primary.vpc_id
}

resource "aws_vpc_security_group_ingress_rule" "db_primary_from_app" {
  provider = aws.primary

  security_group_id            = aws_security_group.db_primary.id
  description                  = "PostgreSQL desde la app"
  referenced_security_group_id = module.app_primary.app_security_group_id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
}

resource "aws_vpc_security_group_egress_rule" "app_primary_to_db" {
  provider = aws.primary

  security_group_id            = module.app_primary.app_security_group_id
  description                  = "App hacia PostgreSQL"
  referenced_security_group_id = aws_security_group.db_primary.id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
}

resource "aws_security_group" "db_dr" {
  provider = aws.dr

  name_prefix = "${local.prefix}-db-"
  description = "Aurora: solo desde la app"
  vpc_id      = module.vpc_dr.vpc_id
}

resource "aws_vpc_security_group_ingress_rule" "db_dr_from_app" {
  provider = aws.dr

  security_group_id            = aws_security_group.db_dr.id
  description                  = "PostgreSQL desde la app"
  referenced_security_group_id = module.app_dr.app_security_group_id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
}

resource "aws_vpc_security_group_egress_rule" "app_dr_to_db" {
  provider = aws.dr

  security_group_id            = module.app_dr.app_security_group_id
  description                  = "App hacia PostgreSQL"
  referenced_security_group_id = aws_security_group.db_dr.id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
}

# --- Enhanced Monitoring (métricas del SO cada 60 s). IAM es global: un rol sirve a ambas regiones.
data "aws_iam_policy_document" "rds_monitoring_assume" {
  provider = aws.primary

  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["monitoring.rds.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "rds_monitoring" {
  provider = aws.primary

  name_prefix        = "${local.prefix}-rds-mon-"
  assume_role_policy = data.aws_iam_policy_document.rds_monitoring_assume.json
}

resource "aws_iam_role_policy_attachment" "rds_monitoring" {
  provider = aws.primary

  role       = aws_iam_role.rds_monitoring.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}

# --- Cluster primario -----------------------------------------------------------
resource "aws_rds_cluster" "primary" {
  #checkov:skip=CKV2_AWS_27:log_statement=all registraría datos personales; se activa por sesión al diagnosticar.
  #checkov:skip=CKV2_AWS_8:Aurora tiene backups automáticos con PITR (14 días) y réplica en otra región vía Global Database.
  provider = aws.primary

  cluster_identifier        = "${local.prefix}-primary"
  global_cluster_identifier = aws_rds_global_cluster.this.id
  engine                    = aws_rds_global_cluster.this.engine
  engine_version            = aws_rds_global_cluster.this.engine_version
  database_name             = "app"

  master_username            = "app_admin"
  master_password_wo         = ephemeral.random_password.db_master.result
  master_password_wo_version = var.db_password_version

  db_subnet_group_name   = aws_db_subnet_group.primary.name
  vpc_security_group_ids = [aws_security_group.db_primary.id]

  storage_encrypted = true
  kms_key_id        = aws_kms_key.db_primary.arn

  backup_retention_period             = 14
  preferred_backup_window             = "06:00-07:00" # 03:00-04:00 hora de Chile
  copy_tags_to_snapshot               = true
  deletion_protection                 = var.deletion_protection
  skip_final_snapshot                 = false
  final_snapshot_identifier           = "${local.prefix}-primary-final"
  iam_database_authentication_enabled = true
  enabled_cloudwatch_logs_exports     = ["postgresql"]

  lifecycle {
    # Tras un switchover/failover global, AWS cambia estos valores fuera de Terraform.
    ignore_changes = [replication_source_identifier, global_cluster_identifier]
  }
}

resource "aws_rds_cluster_instance" "primary" {
  provider = aws.primary
  count    = var.db_primary_instance_count

  identifier           = "${local.prefix}-primary-${count.index}"
  cluster_identifier   = aws_rds_cluster.primary.id
  engine               = aws_rds_cluster.primary.engine
  engine_version       = aws_rds_cluster.primary.engine_version
  instance_class       = var.db_instance_class
  db_subnet_group_name = aws_db_subnet_group.primary.name

  performance_insights_enabled    = true
  performance_insights_kms_key_id = aws_kms_key.db_primary.arn
  monitoring_interval             = 60
  monitoring_role_arn             = aws_iam_role.rds_monitoring.arn
  auto_minor_version_upgrade      = true
  promotion_tier                  = count.index
}

# --- Cluster secundario (DR, solo lectura hasta el failover) -----------------
resource "aws_rds_cluster" "dr" {
  #checkov:skip=CKV2_AWS_27:log_statement=all registraría datos personales; se activa por sesión al diagnosticar.
  #checkov:skip=CKV2_AWS_8:Aurora tiene backups automáticos con PITR (14 días) y réplica en otra región vía Global Database.
  provider = aws.dr

  cluster_identifier        = "${local.prefix}-dr"
  global_cluster_identifier = aws_rds_global_cluster.this.id
  engine                    = aws_rds_global_cluster.this.engine
  engine_version            = aws_rds_global_cluster.this.engine_version

  db_subnet_group_name   = aws_db_subnet_group.dr.name
  vpc_security_group_ids = [aws_security_group.db_dr.id]

  storage_encrypted = true
  kms_key_id        = aws_kms_key.db_dr.arn

  backup_retention_period             = 7
  copy_tags_to_snapshot               = true
  iam_database_authentication_enabled = true
  deletion_protection                 = var.deletion_protection
  skip_final_snapshot                 = true
  enabled_cloudwatch_logs_exports     = ["postgresql"]

  lifecycle {
    ignore_changes = [replication_source_identifier, global_cluster_identifier]
  }

  # El secundario solo puede unirse al global cluster cuando el primario tiene un writer.
  depends_on = [aws_rds_cluster_instance.primary]
}

resource "aws_rds_cluster_instance" "dr" {
  provider = aws.dr
  count    = var.db_dr_instance_count

  identifier           = "${local.prefix}-dr-${count.index}"
  cluster_identifier   = aws_rds_cluster.dr.id
  engine               = aws_rds_cluster.dr.engine
  engine_version       = aws_rds_cluster.dr.engine_version
  instance_class       = var.db_instance_class
  db_subnet_group_name = aws_db_subnet_group.dr.name

  performance_insights_enabled    = true
  performance_insights_kms_key_id = aws_kms_key.db_dr.arn
  monitoring_interval             = 60
  monitoring_role_arn             = aws_iam_role.rds_monitoring.arn
  auto_minor_version_upgrade      = true
}

# --- Vigilancia del RPO: lag de replicación global ---------------------------
resource "aws_cloudwatch_metric_alarm" "global_replication_lag" {
  provider = aws.dr

  alarm_name          = "${local.prefix}-aurora-global-replication-lag"
  alarm_description   = "El lag de replicación hacia DR pone en riesgo el RPO < 1 min. Ver runbooks/failover.md."
  namespace           = "AWS/RDS"
  metric_name         = "AuroraGlobalDBReplicationLag"
  dimensions          = { DBClusterIdentifier = aws_rds_cluster.dr.cluster_identifier }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 3
  datapoints_to_alarm = 2
  threshold           = var.replication_lag_threshold_ms
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "breaching"

  alarm_actions = compact([var.alarm_topic_arns.dr])
  ok_actions    = compact([var.alarm_topic_arns.dr])
}

# =============================================================================
# DNS: failover activo-pasivo con Route 53
# =============================================================================
resource "aws_route53_health_check" "primary" {
  count    = local.dns_enable ? 1 : 0
  provider = aws.primary # Route 53 es global; se usa cualquier alias configurado

  fqdn              = module.app_primary.alb_dns_name
  type              = var.certificate_arns.primary == null ? "HTTP" : "HTTPS"
  port              = var.certificate_arns.primary == null ? 80 : 443
  resource_path     = module.app_primary.health_check_path
  request_interval  = 10
  failure_threshold = 3
  regions           = ["us-east-1", "us-west-2", "sa-east-1"]

  tags = { Name = "${local.prefix}-primary" }
}

resource "aws_route53_health_check" "dr" {
  count    = local.dns_enable ? 1 : 0
  provider = aws.primary # Route 53 es global; se usa cualquier alias configurado

  fqdn              = module.app_dr.alb_dns_name
  type              = var.certificate_arns.dr == null ? "HTTP" : "HTTPS"
  port              = var.certificate_arns.dr == null ? 80 : 443
  resource_path     = module.app_dr.health_check_path
  request_interval  = 30
  failure_threshold = 3
  regions           = ["us-east-1", "us-west-2", "sa-east-1"]

  tags = { Name = "${local.prefix}-dr" }
}

resource "aws_route53_record" "primary" {
  count    = local.dns_enable ? 1 : 0
  provider = aws.primary # Route 53 es global; se usa cualquier alias configurado

  zone_id         = var.route53_zone_id
  name            = var.app_fqdn
  type            = "A"
  set_identifier  = "primary"
  health_check_id = aws_route53_health_check.primary[0].id

  failover_routing_policy {
    type = "PRIMARY"
  }

  alias {
    name                   = module.app_primary.alb_dns_name
    zone_id                = module.app_primary.alb_zone_id
    evaluate_target_health = true
  }
}

resource "aws_route53_record" "dr" {
  count    = local.dns_enable ? 1 : 0
  provider = aws.primary # Route 53 es global; se usa cualquier alias configurado

  zone_id         = var.route53_zone_id
  name            = var.app_fqdn
  type            = "A"
  set_identifier  = "dr"
  health_check_id = aws_route53_health_check.dr[0].id

  failover_routing_policy {
    type = "SECONDARY"
  }

  alias {
    name                   = module.app_dr.alb_dns_name
    zone_id                = module.app_dr.alb_zone_id
    evaluate_target_health = true
  }
}

# Alarma en us-east-1: las métricas de health checks de Route 53 solo existen ahí.
resource "aws_cloudwatch_metric_alarm" "primary_unhealthy" {
  count    = local.dns_enable ? 1 : 0
  provider = aws.us_east_1

  alarm_name          = "${local.prefix}-primary-region-unhealthy"
  alarm_description   = "La región primaria no responde: Route 53 está enviando tráfico a DR. Ejecutar runbooks/failover.md."
  namespace           = "AWS/Route53"
  metric_name         = "HealthCheckStatus"
  dimensions          = { HealthCheckId = aws_route53_health_check.primary[0].id }
  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = 2
  threshold           = 1
  comparison_operator = "LessThanThreshold"

  alarm_actions = compact([var.alarm_topic_arns.us_east_1])
}
