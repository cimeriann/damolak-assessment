terraform {
  required_version = ">= 1.15.1"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.50"
    }
  }
}

variable "name" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "subnet_ids" {
  description = "Private subnets to place container instances in."
  type        = list(string)
}

variable "instance_type" {
  type    = string
  default = "t3.small"
}

variable "asg_min_size" {
  type    = number
  default = 1
}

variable "asg_max_size" {
  type    = number
  default = 4
}

variable "asg_desired_capacity" {
  type    = number
  default = 2
}

variable "alb_security_group_id" {
  description = "ALB SG — allowed to reach the ephemeral port range on container instances."
  type        = string
}

variable "tags" {
  type    = map(string)
  default = {}
}

locals {
  base_tags = merge(var.tags, { Module = "ecs-cluster-ec2" })
}

# --- AMI: ECS-optimized AL2023, resolved from SSM ----------------------------

data "aws_ssm_parameter" "ecs_ami" {
  name = "/aws/service/ecs/optimized-ami/amazon-linux-2023/recommended/image_id"
}

# --- Cluster -----------------------------------------------------------------

resource "aws_ecs_cluster" "this" {
  name = var.name

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = local.base_tags
}

# --- IAM for container instances --------------------------------------------

data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ec2" {
  name               = "${var.name}-ecs-instance-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
  tags               = local.base_tags
}

resource "aws_iam_role_policy_attachment" "ecs_agent" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role"
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ec2" {
  name = "${var.name}-ecs-instance-profile"
  role = aws_iam_role.ec2.name
  tags = local.base_tags
}

# --- Security group: ALB → ephemeral ports ----------------------------------

resource "aws_security_group" "instances" {
  name        = "${var.name}-ecs-instances"
  description = "ECS container instances for ${var.name}"
  vpc_id      = var.vpc_id

  # Ephemeral port range for bridge-mode dynamic port mapping
  ingress {
    description     = "ALB to ephemeral ports"
    from_port       = 32768
    to_port         = 65535
    protocol        = "tcp"
    security_groups = [var.alb_security_group_id]
  }

  egress {
    description = "All egress"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.base_tags, { Name = "${var.name}-ecs-instances-sg" })
}

# --- Launch template + ASG ---------------------------------------------------

locals {
  user_data = base64encode(<<-EOT
    #!/bin/bash
    set -euo pipefail
    echo "ECS_CLUSTER=${aws_ecs_cluster.this.name}" >> /etc/ecs/ecs.config
    echo "ECS_ENABLE_CONTAINER_METADATA=true"      >> /etc/ecs/ecs.config
    echo "ECS_AVAILABLE_LOGGING_DRIVERS=[\"json-file\",\"awslogs\"]" >> /etc/ecs/ecs.config
    echo "ECS_RESERVED_MEMORY=128"                 >> /etc/ecs/ecs.config
  EOT
  )
}

resource "aws_launch_template" "this" {
  name_prefix   = "${var.name}-ecs-"
  image_id      = data.aws_ssm_parameter.ecs_ami.value
  instance_type = var.instance_type

  iam_instance_profile {
    arn = aws_iam_instance_profile.ec2.arn
  }

  vpc_security_group_ids = [aws_security_group.instances.id]
  user_data              = local.user_data

  metadata_options {
    http_tokens                 = "required"
    http_endpoint               = "enabled"
    http_put_response_hop_limit = 2
  }

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = 30
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  tag_specifications {
    resource_type = "instance"
    tags          = merge(local.base_tags, { Name = "${var.name}-ecs-instance" })
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_autoscaling_group" "this" {
  name_prefix         = "${var.name}-ecs-"
  vpc_zone_identifier = var.subnet_ids

  min_size         = var.asg_min_size
  max_size         = var.asg_max_size
  desired_capacity = var.asg_desired_capacity

  health_check_type         = "EC2"
  health_check_grace_period = 90
  protect_from_scale_in     = true # required for managed termination protection

  launch_template {
    id      = aws_launch_template.this.id
    version = "$Latest"
  }

  tag {
    key                 = "Name"
    value               = "${var.name}-ecs-instance"
    propagate_at_launch = true
  }

  tag {
    key                 = "AmazonECSManaged"
    value               = "true"
    propagate_at_launch = true
  }

  dynamic "tag" {
    for_each = local.base_tags
    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = true
    }
  }

  lifecycle {
    create_before_destroy = true
    ignore_changes        = [desired_capacity] # let ECS managed scaling drive this
  }
}

# --- Capacity provider -------------------------------------------------------

resource "aws_ecs_capacity_provider" "this" {
  name = "${var.name}-cp"

  auto_scaling_group_provider {
    auto_scaling_group_arn         = aws_autoscaling_group.this.arn
    managed_termination_protection = "ENABLED"

    managed_scaling {
      status                    = "ENABLED"
      target_capacity           = 100
      minimum_scaling_step_size = 1
      maximum_scaling_step_size = 2
      instance_warmup_period    = 120
    }
  }

  tags = local.base_tags
}

resource "aws_ecs_cluster_capacity_providers" "this" {
  cluster_name       = aws_ecs_cluster.this.name
  capacity_providers = [aws_ecs_capacity_provider.this.name]

  default_capacity_provider_strategy {
    capacity_provider = aws_ecs_capacity_provider.this.name
    weight            = 1
    base              = 1
  }
}

output "cluster_name" {
  value = aws_ecs_cluster.this.name
}

output "cluster_arn" {
  value = aws_ecs_cluster.this.arn
}

output "capacity_provider_name" {
  value = aws_ecs_capacity_provider.this.name
}

output "instance_security_group_id" {
  value = aws_security_group.instances.id
}

output "asg_name" {
  value = aws_autoscaling_group.this.name
}
