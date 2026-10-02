# =============================================================================
# Permissions boundary para roles creados por equipos de desarrollo
# =============================================================================
# Patrón de delegación segura: los equipos pueden crear sus propios roles (p. ej.
# para sus Lambdas) siempre que adjunten este boundary. Así nadie puede crear un
# rol con más permisos que los que el boundary permite, ni quitárselo.

locals {
  boundary_name = "${var.name}-developer-boundary"
  boundary_arn  = "arn:${local.partition}:iam::${local.account_id}:policy/${local.boundary_name}"
}

data "aws_iam_policy_document" "developer_boundary" {
  #checkov:skip=CKV_AWS_111:Es un permissions boundary (techo de permisos), no una concesión; los permisos efectivos son la intersección con la política del rol.
  #checkov:skip=CKV_AWS_356:Es un permissions boundary: el alcance por recurso lo define la política del rol.
  #checkov:skip=CKV_AWS_109:Es un permissions boundary: la gestión de permisos está condicionada a iam:PermissionsBoundary.
  #checkov:skip=CKV_AWS_110:La creación de roles exige adjuntar este mismo boundary y está prohibido quitarlo.
  #checkov:skip=CKV_AWS_108:Es un techo de permisos para servicios de aplicación; el acceso a datos concreto lo concede la política del rol.
  statement {
    sid    = "AllowApplicationServices"
    effect = "Allow"
    actions = [
      "s3:*", "dynamodb:*", "sqs:*", "sns:*", "lambda:*", "events:*", "states:*",
      "logs:*", "cloudwatch:*", "xray:*", "ssm:GetParameter*", "secretsmanager:GetSecretValue",
      "kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey",
    ]
    resources = ["*"]
  }

  # Pueden crear roles solo si llevan este mismo boundary (evita la escalada).
  statement {
    sid       = "CreateRolesOnlyWithBoundary"
    effect    = "Allow"
    actions   = ["iam:CreateRole", "iam:PutRolePolicy", "iam:AttachRolePolicy", "iam:DetachRolePolicy", "iam:DeleteRolePolicy"]
    resources = ["arn:${local.partition}:iam::${local.account_id}:role/app-*"]

    condition {
      test     = "StringEquals"
      variable = "iam:PermissionsBoundary"
      values   = [local.boundary_arn]
    }
  }

  statement {
    sid       = "ManageAppRoles"
    effect    = "Allow"
    actions   = ["iam:GetRole", "iam:PassRole", "iam:DeleteRole", "iam:TagRole", "iam:ListRolePolicies", "iam:ListAttachedRolePolicies"]
    resources = ["arn:${local.partition}:iam::${local.account_id}:role/app-*"]
  }

  statement {
    sid    = "DenyBoundaryTampering"
    effect = "Deny"
    actions = [
      "iam:DeleteRolePermissionsBoundary",
      "iam:DeleteUserPermissionsBoundary",
      "iam:CreatePolicyVersion",
      "iam:DeletePolicy",
      "iam:DeletePolicyVersion",
      "iam:SetDefaultPolicyVersion",
    ]
    resources = [local.boundary_arn, "arn:${local.partition}:iam::${local.account_id}:role/*"]
  }

  statement {
    sid    = "DenySecurityServicesTampering"
    effect = "Deny"
    actions = [
      "cloudtrail:StopLogging", "cloudtrail:DeleteTrail", "cloudtrail:UpdateTrail",
      "config:StopConfigurationRecorder", "config:DeleteConfigurationRecorder", "config:DeleteDeliveryChannel",
      "guardduty:DeleteDetector", "guardduty:UpdateDetector",
      "securityhub:DisableSecurityHub",
      "kms:ScheduleKeyDeletion", "kms:DisableKey",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "developer_boundary" {
  name        = local.boundary_name
  description = "Límite máximo de permisos para roles creados por equipos de aplicación"
  policy      = data.aws_iam_policy_document.developer_boundary.json
}
