terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # El bootstrap usa estado local la primera vez (huevo y gallina).
  # Después de crear el bucket se puede migrar con:
  #   terraform init -migrate-state -backend-config=backend.hcl
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = "aws-cloud-portfolio"
      Component = "bootstrap"
      ManagedBy = "terraform"
    }
  }
}
