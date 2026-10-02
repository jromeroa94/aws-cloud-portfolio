locals {
  https_enabled = var.certificate_arn != null
  tags          = merge(var.tags, { "module" = "app-stack", "DrRole" = var.role })
}

data "aws_region" "current" {}

# AMI más reciente de Amazon Linux 2023 para Graviton, resuelta vía SSM Parameter
# Store: nunca se hardcodea un ID de AMI (que además difiere entre regiones).
data "aws_ssm_parameter" "al2023_arm64" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
}

# ---------------------------------------------------------------------------
# Security groups
# ---------------------------------------------------------------------------
resource "aws_security_group" "alb" {
  name_prefix = "${var.name}-alb-"
  description = "ALB publico"
  vpc_id      = var.vpc_id
  tags        = merge(local.tags, { Name = "${var.name}-alb" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  #checkov:skip=CKV_AWS_260:El puerto 80 público es necesario para redirigir a HTTPS (o para el modo laboratorio sin certificado).
  security_group_id = aws_security_group.alb.id
  description       = "HTTP (redirige a HTTPS si hay certificado)"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
}

resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  count = local.https_enabled ? 1 : 0

  security_group_id = aws_security_group.alb.id
  description       = "HTTPS"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

resource "aws_vpc_security_group_egress_rule" "alb_to_app" {
  security_group_id            = aws_security_group.alb.id
  description                  = "Solo hacia las instancias de la app"
  referenced_security_group_id = aws_security_group.app.id
  ip_protocol                  = "tcp"
  from_port                    = 8080
  to_port                      = 8080
}

resource "aws_security_group" "app" {
  name_prefix = "${var.name}-app-"
  description = "Instancias de la aplicacion"
  vpc_id      = var.vpc_id
  tags        = merge(local.tags, { Name = "${var.name}-app" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "app_from_alb" {
  security_group_id            = aws_security_group.app.id
  description                  = "Trafico desde el ALB"
  referenced_security_group_id = aws_security_group.alb.id
  ip_protocol                  = "tcp"
  from_port                    = 8080
  to_port                      = 8080
}

resource "aws_vpc_security_group_egress_rule" "app_https" {
  security_group_id = aws_security_group.app.id
  description       = "HTTPS saliente (SSM, CloudWatch, repos de paquetes)"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

resource "aws_vpc_security_group_egress_rule" "app_http" {
  security_group_id = aws_security_group.app.id
  description       = "HTTP saliente (repos de paquetes de Amazon Linux)"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
}

# ---------------------------------------------------------------------------
# IAM: acceso por SSM Session Manager (sin SSH ni bastion) y métricas del agente
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "app" {
  name_prefix        = "${substr(var.name, 0, 24)}-app-"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
  tags               = local.tags
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.app.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "cw_agent" {
  role       = aws_iam_role.app.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

resource "aws_iam_instance_profile" "app" {
  name_prefix = "${substr(var.name, 0, 24)}-app-"
  role        = aws_iam_role.app.name
}

# ---------------------------------------------------------------------------
# Launch template + Auto Scaling Group
# ---------------------------------------------------------------------------
resource "aws_launch_template" "app" {
  name_prefix   = "${var.name}-"
  image_id      = data.aws_ssm_parameter.al2023_arm64.insecure_value
  instance_type = var.instance_type

  vpc_security_group_ids = [aws_security_group.app.id]

  iam_instance_profile {
    arn = aws_iam_instance_profile.app.arn
  }

  # IMDSv2 obligatorio: mitiga ataques SSRF contra el endpoint de metadatos.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      volume_size           = 20
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  monitoring {
    enabled = true
  }

  user_data = base64encode(templatefile("${path.module}/templates/user_data.sh.tftpl", {
    dr_role = var.role
  }))

  tag_specifications {
    resource_type = "instance"
    tags          = merge(local.tags, { Name = "${var.name}-app" })
  }

  tag_specifications {
    resource_type = "volume"
    tags          = local.tags
  }

  tags = local.tags
}

resource "aws_autoscaling_group" "app" {
  name_prefix         = "${var.name}-"
  vpc_zone_identifier = var.private_subnet_ids
  target_group_arns   = [aws_lb_target_group.app.arn]

  min_size         = var.min_size
  max_size         = var.max_size
  desired_capacity = var.desired_capacity

  # El ASG reemplaza instancias que el ALB marca como no sanas, no solo las que
  # fallan el chequeo de EC2.
  health_check_type         = "ELB"
  health_check_grace_period = 120
  default_instance_warmup   = 120

  # Reparte entre AZs y prioriza reemplazar instancias antiguas.
  capacity_rebalance   = false
  termination_policies = ["OldestLaunchTemplate", "Default"]

  enabled_metrics = [
    "GroupDesiredCapacity",
    "GroupInServiceInstances",
    "GroupPendingInstances",
    "GroupTerminatingInstances",
  ]

  launch_template {
    id      = aws_launch_template.app.id
    version = aws_launch_template.app.latest_version
  }

  # Cada cambio del launch template dispara un despliegue rolling sin downtime.
  instance_refresh {
    strategy = "Rolling"

    preferences {
      min_healthy_percentage = 90
      instance_warmup        = 120
      auto_rollback          = true
    }
  }

  dynamic "tag" {
    for_each = merge(local.tags, { Name = "${var.name}-app" })

    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = true
    }
  }

  lifecycle {
    # En una conmutación por error el runbook escala el ASG de standby; Terraform
    # no debe revertirlo en el siguiente apply.
    ignore_changes = [desired_capacity]
  }
}

resource "aws_autoscaling_policy" "cpu" {
  name                   = "${var.name}-cpu-target"
  autoscaling_group_name = aws_autoscaling_group.app.name
  policy_type            = "TargetTrackingScaling"

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }

    target_value = var.cpu_target
  }
}

# ---------------------------------------------------------------------------
# Application Load Balancer
# ---------------------------------------------------------------------------
resource "aws_lb" "app" {
  #checkov:skip=CKV2_AWS_76:Falso positivo por count: el WebACL asociado incluye AWSManagedRulesKnownBadInputsRuleSet (Log4JRCE).
  #checkov:skip=CKV2_AWS_20:La redirección HTTP -> HTTPS se crea en cuanto se proporciona certificate_arn (listener http_redirect).
  name_prefix        = substr(replace(var.name, "-", ""), 0, 6)
  load_balancer_type = "application"
  internal           = false
  security_groups    = [aws_security_group.alb.id]
  subnets            = var.public_subnet_ids

  drop_invalid_header_fields = true
  enable_deletion_protection = var.deletion_protection
  idle_timeout               = 60

  dynamic "access_logs" {
    for_each = var.alb_access_logs_bucket == null ? [] : [var.alb_access_logs_bucket]

    content {
      bucket  = access_logs.value
      prefix  = var.name
      enabled = true
    }
  }

  tags = merge(local.tags, { Name = "${var.name}-alb" })
}

resource "aws_lb_target_group" "app" {
  #checkov:skip=CKV_AWS_378:TLS termina en el ALB; el tramo ALB -> instancia va por subredes privadas restringido por security groups.
  name_prefix = substr(replace(var.name, "-", ""), 0, 6)
  port        = 8080
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "instance"

  deregistration_delay = 30

  health_check {
    path                = "/health"
    matcher             = "200"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = local.tags

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_lb_listener" "http_forward" {
  #checkov:skip=CKV_AWS_2:Solo existe en modo laboratorio, cuando no se proporciona certificate_arn.
  #checkov:skip=CKV_AWS_103:Solo existe en modo laboratorio, cuando no se proporciona certificate_arn.
  count = local.https_enabled ? 0 : 1

  load_balancer_arn = aws_lb.app.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}

resource "aws_lb_listener" "http_redirect" {
  count = local.https_enabled ? 1 : 0

  load_balancer_arn = aws_lb.app.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"

    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

resource "aws_lb_listener" "https" {
  count = local.https_enabled ? 1 : 0

  load_balancer_arn = aws_lb.app.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = var.ssl_policy
  certificate_arn   = var.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}

# ---------------------------------------------------------------------------
# AWS WAF: reglas gestionadas de AWS delante del ALB
# ---------------------------------------------------------------------------
resource "aws_wafv2_web_acl" "app" {
  #checkov:skip=CKV2_AWS_31:Falso positivo por count: el logging está en aws_wafv2_web_acl_logging_configuration.app.
  count = var.enable_waf ? 1 : 0

  name        = "${var.name}-waf"
  description = "Reglas gestionadas de AWS + limitacion de peticiones por IP"
  scope       = "REGIONAL"

  default_action {
    allow {}
  }

  rule {
    name     = "AWSManagedRulesAmazonIpReputationList"
    priority = 10

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesAmazonIpReputationList"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "AWSManagedRulesAmazonIpReputationList"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "AWSManagedRulesCommonRuleSet"
    priority = 20

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesCommonRuleSet"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "AWSManagedRulesCommonRuleSet"
      sampled_requests_enabled   = true
    }
  }

  # Incluye la regla Log4JRCE (CVE-2021-44228).
  rule {
    name     = "AWSManagedRulesKnownBadInputsRuleSet"
    priority = 30

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "AWSManagedRulesKnownBadInputsRuleSet"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "rate-limit-per-ip"
    priority = 40

    action {
      block {}
    }

    statement {
      rate_based_statement {
        limit                 = var.waf_rate_limit_per_5min
        aggregate_key_type    = "IP"
        evaluation_window_sec = 300
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "rate-limit-per-ip"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${var.name}-waf"
    sampled_requests_enabled   = true
  }

  tags = local.tags
}

resource "aws_wafv2_web_acl_association" "app" {
  count = var.enable_waf ? 1 : 0

  resource_arn = aws_lb.app.arn
  web_acl_arn  = aws_wafv2_web_acl.app[0].arn
}

# Los log groups de WAF deben empezar por "aws-waf-logs-".
resource "aws_cloudwatch_log_group" "waf" {
  #checkov:skip=CKV_AWS_158:Cifrado por defecto de CloudWatch; Authorization y Cookie se redactan antes de registrar.
  count = var.enable_waf ? 1 : 0

  name              = "aws-waf-logs-${var.name}"
  retention_in_days = 30
  tags              = local.tags
}

resource "aws_wafv2_web_acl_logging_configuration" "app" {
  count = var.enable_waf ? 1 : 0

  resource_arn            = aws_wafv2_web_acl.app[0].arn
  log_destination_configs = [aws_cloudwatch_log_group.waf[0].arn]

  # No registrar cabeceras con credenciales o sesiones.
  redacted_fields {
    single_header {
      name = "authorization"
    }
  }

  redacted_fields {
    single_header {
      name = "cookie"
    }
  }
}
