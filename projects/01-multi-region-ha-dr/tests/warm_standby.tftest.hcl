# Verifica la forma del warm standby sin desplegar nada (proveedores simulados).

mock_provider "aws" {
  alias = "primary"

  mock_data "aws_availability_zones" {
    defaults = { names = ["sa-east-1a", "sa-east-1b", "sa-east-1c"] }
  }
  mock_data "aws_region" {
    defaults = { region = "sa-east-1" }
  }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  mock_data "aws_ssm_parameter" {
    defaults = { insecure_value = "ami-0123456789abcdef0" }
  }
}

mock_provider "aws" {
  alias = "dr"

  mock_data "aws_availability_zones" {
    defaults = { names = ["us-east-1a", "us-east-1b", "us-east-1c"] }
  }
  mock_data "aws_region" {
    defaults = { region = "us-east-1" }
  }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  mock_data "aws_ssm_parameter" {
    defaults = { insecure_value = "ami-0fedcba9876543210" }
  }
}

mock_provider "aws" {
  alias = "us_east_1"
}

# random se usa real: no necesita credenciales y los mocks no soportan recursos efímeros.

run "warm_standby_reducido_en_dr" {
  command = plan

  assert {
    condition     = length(module.vpc_primary.nat_public_ips) == 3 && length(module.vpc_dr.nat_public_ips) == 1
    error_message = "Primaria: NAT por AZ. DR en espera: una sola NAT."
  }

  assert {
    condition     = length(aws_rds_cluster_instance.primary) == 2 && length(aws_rds_cluster_instance.dr) == 1
    error_message = "Aurora: writer + reader en primaria, un reader en DR."
  }

  assert {
    condition     = aws_rds_cluster.primary.storage_encrypted && aws_rds_cluster.dr.storage_encrypted
    error_message = "Ambos clusters deben estar cifrados."
  }

  assert {
    condition     = aws_rds_global_cluster.this.engine == "aurora-postgresql"
    error_message = "El global cluster debe ser Aurora PostgreSQL."
  }
}

run "sin_dns_no_crea_failover" {
  command = plan

  assert {
    condition     = length(aws_route53_record.primary) == 0 && length(aws_route53_health_check.primary) == 0
    error_message = "Sin zona DNS no deben crearse registros ni health checks."
  }
}

run "con_dns_crea_failover_activo_pasivo" {
  command = plan

  variables {
    route53_zone_id = "Z0123456789ABCDEFGHIJ"
    app_fqdn        = "app.ejemplo.cl"
  }

  assert {
    condition     = aws_route53_record.primary[0].failover_routing_policy[0].type == "PRIMARY" && aws_route53_record.dr[0].failover_routing_policy[0].type == "SECONDARY"
    error_message = "Los registros deben formar un par PRIMARY/SECONDARY."
  }
}
