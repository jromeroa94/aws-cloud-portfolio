# =============================================================================
# Alertas de seguridad
# =============================================================================
resource "aws_sns_topic" "security_alerts" {
  name              = "${var.name}-alerts"
  kms_master_key_id = aws_kms_key.audit.arn
}

data "aws_iam_policy_document" "security_alerts" {
  statement {
    sid       = "AllowEventBridgeAndCloudWatch"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.security_alerts.arn]

    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com", "cloudwatch.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_sns_topic_policy" "security_alerts" {
  arn    = aws_sns_topic.security_alerts.arn
  policy = data.aws_iam_policy_document.security_alerts.json
}

resource "aws_sns_topic_subscription" "email" {
  for_each = toset(var.security_alert_emails)

  topic_arn = aws_sns_topic.security_alerts.arn
  protocol  = "email"
  endpoint  = each.value
}

# -----------------------------------------------------------------------------
# Filtros de métricas sobre CloudTrail (controles CloudWatch.1–14 de CIS)
# -----------------------------------------------------------------------------
locals {
  cis_metric_filters = {
    root-account-usage = {
      pattern     = "{ $.userIdentity.type = \"Root\" && $.userIdentity.invokedBy NOT EXISTS && $.eventType != \"AwsServiceEvent\" }"
      description = "Uso de la cuenta root"
    }
    unauthorized-api-calls = {
      pattern     = "{ ($.errorCode = \"*UnauthorizedOperation\") || ($.errorCode = \"AccessDenied*\") }"
      description = "Llamadas a la API denegadas"
    }
    console-login-without-mfa = {
      pattern     = "{ ($.eventName = \"ConsoleLogin\") && ($.additionalEventData.MFAUsed != \"Yes\") && ($.userIdentity.type = \"IAMUser\") && ($.responseElements.ConsoleLogin = \"Success\") }"
      description = "Inicio de sesión en consola sin MFA"
    }
    console-login-failures = {
      pattern     = "{ ($.eventName = ConsoleLogin) && ($.errorMessage = \"Failed authentication\") }"
      description = "Fallos de autenticación en consola"
    }
    iam-policy-changes = {
      pattern     = "{ ($.eventSource = iam.amazonaws.com) && (($.eventName = DeleteGroupPolicy) || ($.eventName = DeleteRolePolicy) || ($.eventName = DeleteUserPolicy) || ($.eventName = PutGroupPolicy) || ($.eventName = PutRolePolicy) || ($.eventName = PutUserPolicy) || ($.eventName = CreatePolicy) || ($.eventName = DeletePolicy) || ($.eventName = CreatePolicyVersion) || ($.eventName = DeletePolicyVersion) || ($.eventName = AttachRolePolicy) || ($.eventName = DetachRolePolicy) || ($.eventName = AttachUserPolicy) || ($.eventName = DetachUserPolicy) || ($.eventName = AttachGroupPolicy) || ($.eventName = DetachGroupPolicy)) }"
      description = "Cambios en políticas de IAM"
    }
    cloudtrail-config-changes = {
      pattern     = "{ ($.eventName = CreateTrail) || ($.eventName = UpdateTrail) || ($.eventName = DeleteTrail) || ($.eventName = StartLogging) || ($.eventName = StopLogging) }"
      description = "Cambios en la configuración de CloudTrail"
    }
    kms-key-disable-or-deletion = {
      pattern     = "{ ($.eventSource = kms.amazonaws.com) && (($.eventName = DisableKey) || ($.eventName = ScheduleKeyDeletion)) }"
      description = "Claves KMS deshabilitadas o programadas para borrado"
    }
    s3-bucket-policy-changes = {
      pattern     = "{ ($.eventSource = s3.amazonaws.com) && (($.eventName = PutBucketAcl) || ($.eventName = PutBucketPolicy) || ($.eventName = PutBucketCors) || ($.eventName = PutBucketLifecycle) || ($.eventName = PutBucketReplication) || ($.eventName = DeleteBucketPolicy) || ($.eventName = DeleteBucketCors) || ($.eventName = DeleteBucketLifecycle) || ($.eventName = DeleteBucketReplication)) }"
      description = "Cambios en políticas de buckets S3"
    }
    config-changes = {
      pattern     = "{ ($.eventSource = config.amazonaws.com) && (($.eventName = StopConfigurationRecorder) || ($.eventName = DeleteDeliveryChannel) || ($.eventName = PutDeliveryChannel) || ($.eventName = PutConfigurationRecorder)) }"
      description = "Cambios en AWS Config"
    }
    security-group-changes = {
      pattern     = "{ ($.eventName = AuthorizeSecurityGroupIngress) || ($.eventName = AuthorizeSecurityGroupEgress) || ($.eventName = RevokeSecurityGroupIngress) || ($.eventName = RevokeSecurityGroupEgress) || ($.eventName = CreateSecurityGroup) || ($.eventName = DeleteSecurityGroup) }"
      description = "Cambios en security groups"
    }
    nacl-changes = {
      pattern     = "{ ($.eventName = CreateNetworkAcl) || ($.eventName = CreateNetworkAclEntry) || ($.eventName = DeleteNetworkAcl) || ($.eventName = DeleteNetworkAclEntry) || ($.eventName = ReplaceNetworkAclEntry) || ($.eventName = ReplaceNetworkAclAssociation) }"
      description = "Cambios en NACLs"
    }
    network-gateway-changes = {
      pattern     = "{ ($.eventName = CreateCustomerGateway) || ($.eventName = DeleteCustomerGateway) || ($.eventName = AttachInternetGateway) || ($.eventName = CreateInternetGateway) || ($.eventName = DeleteInternetGateway) || ($.eventName = DetachInternetGateway) }"
      description = "Cambios en gateways de red"
    }
    route-table-changes = {
      pattern     = "{ ($.eventSource = ec2.amazonaws.com) && (($.eventName = CreateRoute) || ($.eventName = CreateRouteTable) || ($.eventName = ReplaceRoute) || ($.eventName = ReplaceRouteTableAssociation) || ($.eventName = DeleteRouteTable) || ($.eventName = DeleteRoute) || ($.eventName = DisassociateRouteTable)) }"
      description = "Cambios en tablas de rutas"
    }
    vpc-changes = {
      pattern     = "{ ($.eventName = CreateVpc) || ($.eventName = DeleteVpc) || ($.eventName = ModifyVpcAttribute) || ($.eventName = AcceptVpcPeeringConnection) || ($.eventName = CreateVpcPeeringConnection) || ($.eventName = DeleteVpcPeeringConnection) || ($.eventName = RejectVpcPeeringConnection) }"
      description = "Cambios en VPCs"
    }
  }
}

resource "aws_cloudwatch_log_metric_filter" "cis" {
  for_each = local.cis_metric_filters

  name           = each.key
  log_group_name = aws_cloudwatch_log_group.cloudtrail.name
  pattern        = each.value.pattern

  metric_transformation {
    name          = each.key
    namespace     = "SecurityBaseline/CIS"
    value         = "1"
    default_value = "0"
  }
}

resource "aws_cloudwatch_metric_alarm" "cis" {
  for_each = local.cis_metric_filters

  alarm_name          = "cis-${each.key}"
  alarm_description   = each.value.description
  namespace           = "SecurityBaseline/CIS"
  metric_name         = aws_cloudwatch_log_metric_filter.cis[each.key].metric_transformation[0].name
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = each.key == "unauthorized-api-calls" ? 10 : 1 # las denegaciones aisladas son ruido
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.security_alerts.arn]
}

# -----------------------------------------------------------------------------
# Hallazgos de GuardDuty y Security Hub -> SNS
# -----------------------------------------------------------------------------
resource "aws_cloudwatch_event_rule" "guardduty_high" {
  name        = "${var.name}-guardduty-high"
  description = "Hallazgos de GuardDuty con severidad >= ${var.guardduty_alert_min_severity}"

  event_pattern = jsonencode({
    source      = ["aws.guardduty"]
    detail-type = ["GuardDuty Finding"]
    detail      = { severity = [{ numeric = [">=", var.guardduty_alert_min_severity] }] }
  })
}

resource "aws_cloudwatch_event_target" "guardduty_high" {
  rule = aws_cloudwatch_event_rule.guardduty_high.name
  arn  = aws_sns_topic.security_alerts.arn

  # Mensaje legible en lugar del JSON completo del hallazgo.
  input_transformer {
    input_paths = {
      severity = "$.detail.severity"
      type     = "$.detail.type"
      title    = "$.detail.title"
      account  = "$.detail.accountId"
      region   = "$.region"
    }
    input_template = "\"GuardDuty [<severity>] <type> en <account>/<region>: <title>\""
  }
}

resource "aws_cloudwatch_event_rule" "securityhub_critical" {
  name        = "${var.name}-securityhub-critical"
  description = "Hallazgos nuevos de Security Hub con severidad CRITICAL"

  event_pattern = jsonencode({
    source      = ["aws.securityhub"]
    detail-type = ["Security Hub Findings - Imported"]
    detail = {
      findings = {
        Severity    = { Label = ["CRITICAL"] }
        Workflow    = { Status = ["NEW"] }
        RecordState = ["ACTIVE"]
      }
    }
  })
}

resource "aws_cloudwatch_event_target" "securityhub_critical" {
  rule = aws_cloudwatch_event_rule.securityhub_critical.name
  arn  = aws_sns_topic.security_alerts.arn
}
