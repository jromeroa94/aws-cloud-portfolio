terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  backend "s3" {
    key          = "projects/05-observability/terraform.tfstate"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project     = "aws-cloud-portfolio"
      Component   = "observability"
      Environment = var.environment
      ManagedBy   = "terraform"
      CostCenter  = "platform"
    }
  }
}
