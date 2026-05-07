# `bucket` is supplied via `terraform init -backend-config=...`; see README.
terraform {
  backend "s3" {
    key          = "envs/prod/terraform.tfstate"
    region       = "us-east-1"
    use_lockfile = true
    encrypt      = true
  }
}
