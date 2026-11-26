# Terraform と使うプロバイダーのバージョンを固定する
terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.70"
    }
    # Lambda のコードを zip にまとめるために使う
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
  }
}

provider "aws" {
  region = var.region

  # 作ったリソースすべてに共通のタグを付ける
  # DevOps Agent のスキルでも「Project=ops-lab のリソースだけ調べる」と指示している
  default_tags {
    tags = {
      Project   = var.project
      ManagedBy = "terraform"
    }
  }
}
