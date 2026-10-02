terraform {
  required_version = ">= 1.11" # atributos write-only (master_password_wo) y recursos efímeros

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.7"
    }
  }

  # Backend parcial: bucket y región llegan por -backend-config (ver bootstrap/).
  backend "s3" {
    key          = "projects/01-multi-region-ha-dr/terraform.tfstate"
    encrypt      = true
    use_lockfile = true
  }
}

locals {
  default_tags = {
    Project     = "aws-cloud-portfolio"
    Component   = "multi-region-ha-dr"
    Environment = var.environment
    ManagedBy   = "terraform"
    CostCenter  = var.cost_center
  }
}

provider "aws" {
  alias  = "primary"
  region = var.primary_region

  default_tags {
    tags = local.default_tags
  }
}

provider "aws" {
  alias  = "dr"
  region = var.dr_region

  default_tags {
    tags = local.default_tags
  }
}

# Las métricas de los health checks de Route 53 solo se publican en us-east-1,
# independientemente de la región de DR elegida.
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"

  default_tags {
    tags = local.default_tags
  }
}
