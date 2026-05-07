terraform {
  required_version = ">= 1.15.1"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.50"
    }
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project     = var.project
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}

locals {
  name = "${var.project}-${var.environment}"
  tags = {
    Project     = var.project
    Environment = var.environment
  }
}

# --- Network ----------------------------------------------------------------

module "vpc" {
  source = "../../modules/vpc"

  name                 = local.name
  cidr                 = var.vpc_cidr
  azs                  = var.azs
  public_subnet_cidrs  = ["10.40.0.0/24", "10.40.1.0/24"]
  private_subnet_cidrs = ["10.40.10.0/24", "10.40.11.0/24"]
  single_nat_gateway   = true
  tags                 = local.tags
}

# --- App image registry -----------------------------------------------------

module "ecr_app" {
  source = "../../modules/ecr"

  name         = "${local.name}-app"
  force_delete = true
  tags         = local.tags
}

module "ecr_jenkins" {
  source = "../../modules/ecr"

  name                  = "${local.name}-jenkins"
  image_retention_count = 5
  force_delete          = true
  tags                  = local.tags
}

# --- Load balancer ----------------------------------------------------------

module "alb" {
  source = "../../modules/alb"

  name              = local.name
  vpc_id            = module.vpc.vpc_id
  public_subnet_ids = module.vpc.public_subnet_ids
  health_check_path = "/healthz"
  tags              = local.tags
}

# --- ECS cluster on EC2 -----------------------------------------------------

module "ecs_cluster" {
  source = "../../modules/ecs-cluster-ec2"

  name                  = local.name
  vpc_id                = module.vpc.vpc_id
  subnet_ids            = module.vpc.private_subnet_ids
  instance_type         = var.ecs_instance_type
  asg_min_size          = var.ecs_asg_min
  asg_max_size          = var.ecs_asg_max
  asg_desired_capacity  = var.ecs_asg_desired
  alb_security_group_id = module.alb.alb_security_group_id
  tags                  = local.tags
}

# --- App service ------------------------------------------------------------

module "ecs_service" {
  source = "../../modules/ecs-service"

  name                   = "${local.name}-app"
  cluster_arn            = module.ecs_cluster.cluster_arn
  capacity_provider_name = module.ecs_cluster.capacity_provider_name
  container_port         = var.app_container_port
  image                  = var.app_initial_image
  cpu                    = var.app_cpu
  memory                 = var.app_memory
  desired_count          = var.app_desired_count
  target_group_arn       = module.alb.target_group_arn
  log_retention_days     = var.log_retention_days
  region                 = var.region
  tags                   = local.tags
}

# --- Jenkins ----------------------------------------------------------------

module "jenkins" {
  source = "../../modules/jenkins"

  name          = "${local.name}-jenkins"
  vpc_id        = module.vpc.vpc_id
  subnet_id     = module.vpc.public_subnet_ids[0]
  instance_type = var.jenkins_instance_type
  admin_cidr    = var.jenkins_admin_cidr
  key_name      = var.jenkins_key_name
  jenkins_image = var.jenkins_image
  region        = var.region

  jenkins_admin_user     = "admin"
  jenkins_admin_password = var.jenkins_admin_password

  ecr_app_repository_arn     = module.ecr_app.repository_arn
  ecr_app_repository_url     = module.ecr_app.repository_url
  ecr_jenkins_repository_arn = module.ecr_jenkins.repository_arn
  ecs_cluster_name           = module.ecs_cluster.cluster_name
  ecs_service_name           = module.ecs_service.service_name
  ecs_task_family            = module.ecs_service.task_family

  repo_url    = var.repo_url
  repo_branch = var.repo_branch

  tags = local.tags
}

# --- Monitoring -------------------------------------------------------------

module "monitoring" {
  source = "../../modules/monitoring"

  name                    = local.name
  region                  = var.region
  log_retention_days      = var.log_retention_days
  alarm_email             = var.alarm_email
  alb_arn_suffix          = module.alb.alb_arn_suffix
  target_group_arn_suffix = module.alb.target_group_arn_suffix
  ecs_cluster_name        = module.ecs_cluster.cluster_name
  ecs_service_name        = module.ecs_service.service_name
  ecs_desired_count       = var.app_desired_count
  app_log_group_name      = module.ecs_service.log_group_name
  tags                    = local.tags
}
