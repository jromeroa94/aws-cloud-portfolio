# Tests de plan con proveedor simulado: no necesitan credenciales de AWS.
#   terraform init && terraform test

mock_provider "aws" {
  mock_data "aws_availability_zones" {
    defaults = {
      names = ["sa-east-1a", "sa-east-1b", "sa-east-1c"]
    }
  }

  mock_data "aws_region" {
    defaults = {
      region = "sa-east-1"
    }
  }

  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
}

variables {
  name       = "test"
  cidr_block = "10.10.0.0/16"
}

run "produccion_una_nat_por_az" {
  command = plan

  variables {
    az_count         = 3
    nat_gateway_mode = "per_az"
  }

  assert {
    condition     = length(aws_nat_gateway.this) == 3
    error_message = "per_az debe crear una NAT Gateway por AZ."
  }

  assert {
    condition     = length(aws_route.private_nat) == 3
    error_message = "Cada tabla privada necesita su ruta por defecto."
  }

  assert {
    condition     = aws_subnet.public[0].cidr_block == "10.10.0.0/20" && aws_subnet.private[0].cidr_block == "10.10.64.0/20" && aws_subnet.data[0].cidr_block == "10.10.128.0/20"
    error_message = "Las subredes no siguen el esquema de direccionamiento esperado."
  }

  assert {
    condition     = alltrue([for s in aws_subnet.public : s.map_public_ip_on_launch == false])
    error_message = "Ninguna subred debe asignar IP pública automáticamente."
  }
}

run "desarrollo_una_sola_nat" {
  command = plan

  variables {
    az_count         = 2
    nat_gateway_mode = "single"
  }

  assert {
    condition     = length(aws_nat_gateway.this) == 1 && length(aws_route.private_nat) == 2
    error_message = "single debe crear una NAT compartida por todas las tablas privadas."
  }
}

run "aislada_sin_nat" {
  command = plan

  variables {
    nat_gateway_mode = "none"
  }

  assert {
    condition     = length(aws_nat_gateway.this) == 0 && length(aws_route.private_nat) == 0
    error_message = "none no debe crear NAT ni rutas a Internet en la capa privada."
  }

  assert {
    condition     = length(aws_vpc_endpoint.s3) == 1
    error_message = "Sin NAT, el endpoint de S3 es la única salida a S3."
  }
}

run "rechaza_una_sola_az" {
  command = plan

  variables {
    az_count = 1
  }

  expect_failures = [var.az_count]
}

run "flow_logs_desactivables" {
  command = plan

  variables {
    flow_logs_retention_days = 0
  }

  assert {
    condition     = length(aws_flow_log.this) == 0 && length(aws_iam_role.flow_logs) == 0
    error_message = "Con retención 0 no deben crearse Flow Logs."
  }
}
