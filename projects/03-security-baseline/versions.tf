terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  backend "s3" {
    key          = "projects/03-security-baseline/terraform.tfstate"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project     = "aws-cloud-portfolio"
      Component   = "security-baseline"
      Environment = var.environment
      ManagedBy   = "terraform"
      CostCenter  = "security"
    }
  }
}
