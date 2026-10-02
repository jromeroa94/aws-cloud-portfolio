# Tests de plan con proveedor simulado: verifican la lógica de SLO sin credenciales.

mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
    }
  }

  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
}

variables {
  alb_arn_suffix          = "app/test/0123456789abcdef"
  target_group_arn_suffix = "targetgroup/test/0123456789abcdef"
  asg_name                = "test-asg"
  db_cluster_identifier   = "test-db"
  lambda_function_names   = ["fn-a"]
  queue_names             = ["q-ingest"]
  dlq_names               = ["q-ingest-dlq"]
  app_log_group_names     = ["/aws/lambda/fn-a"]
}

run "umbrales_de_burn_rate" {
  command = plan

  assert {
    condition     = length(aws_cloudwatch_metric_alarm.error_ratio) == 4
    error_message = "Se esperan 4 ventanas: fast/slow x long/short."
  }

  assert {
    condition     = abs(aws_cloudwatch_metric_alarm.error_ratio["fast-long"].threshold - 0.0144) < 0.000001
    error_message = "Burn rate rápido: 14.4 x 0.1 % = 1.44 %."
  }

  assert {
    condition     = abs(aws_cloudwatch_metric_alarm.error_ratio["slow-short"].threshold - 0.006) < 0.000001
    error_message = "Burn rate lento: 6 x 0.1 % = 0.6 %."
  }

  assert {
    condition     = output.error_budget_minutes_per_30d == 43
    error_message = "Un SLO de 99.9 % permite 43 minutos al mes."
  }
}

run "dashboard_incluye_todas_las_secciones" {
  command = apply # el cuerpo incluye ARNs de alarmas, conocidos tras el apply simulado

  assert {
    condition     = length(jsondecode(aws_cloudwatch_dashboard.service.dashboard_body).widgets) == 10
    error_message = "El dashboard debe tener 7 widgets base + Aurora + Lambda + colas."
  }
}

run "dashboard_minimo_sin_componentes_opcionales" {
  command = apply # el cuerpo incluye ARNs de alarmas, conocidos tras el apply simulado

  variables {
    db_cluster_identifier = null
    lambda_function_names = []
    queue_names           = []
    dlq_names             = []
    app_log_group_names   = []
  }

  assert {
    condition     = length(jsondecode(aws_cloudwatch_dashboard.service.dashboard_body).widgets) == 7
    error_message = "Sin componentes opcionales solo quedan los widgets base."
  }
}

run "opensearch_exige_red" {
  command = plan

  variables {
    opensearch = { enabled = true }
  }

  expect_failures = [var.opensearch]
}
