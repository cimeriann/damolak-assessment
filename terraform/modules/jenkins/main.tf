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
  type    = string
  default = "jenkins"
}

variable "vpc_id" {
  type = string
}

variable "subnet_id" {
  description = "Public subnet for Jenkins."
  type        = string
}

variable "instance_type" {
  type    = string
  default = "t3.micro"
}

variable "admin_cidr" {
  description = "CIDR allowed to reach Jenkins UI (8080) and SSH (22)."
  type        = string
}

variable "key_name" {
  description = "Existing EC2 key pair name for SSH (leave null to disable)."
  type        = string
  default     = null
}

variable "jenkins_image" {
  description = "Full image URI of the custom Jenkins controller in ECR."
  type        = string
}

variable "jenkins_admin_user" {
  type    = string
  default = "admin"
}

variable "jenkins_admin_password" {
  description = "Initial admin password (rotate via JCasC after first login)."
  type        = string
  sensitive   = true
}

variable "ecr_app_repository_arn" {
  type = string
}

variable "ecs_task_family" {
  type = string
}

variable "ecr_jenkins_repository_arn" {
  description = "ARN of the ECR repo holding the Jenkins controller image. Granted read-only to the instance role so it can pull at boot."
  type        = string
}

variable "ecr_app_repository_url" {
  type = string
}

variable "ecs_cluster_name" {
  type = string
}

variable "ecs_service_name" {
  type = string
}

variable "repo_url" {
  description = "Git URL the pipeline polls (e.g. https://github.com/you/assessment.git)."
  type        = string
}

variable "repo_branch" {
  type    = string
  default = "main"
}

variable "region" {
  type = string
}

variable "jenkins_volume_size" {
  type    = number
  default = 30
}

variable "tags" {
  type    = map(string)
  default = {}
}

locals {
  base_tags = merge(var.tags, { Module = "jenkins" })
}

# --- AMI: Amazon Linux 2023 -------------------------------------------------

data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

# --- Security group ---------------------------------------------------------

resource "aws_security_group" "jenkins" {
  name        = "${var.name}-controller"
  description = "Jenkins controller"
  vpc_id      = var.vpc_id

  ingress {
    description = "Jenkins UI"
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = [var.admin_cidr]
  }

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.admin_cidr]
  }

  egress {
    description = "All egress"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.base_tags, { Name = "${var.name}-sg" })
}

# --- IAM: instance profile -------------------------------------------------

data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "jenkins" {
  name               = "${var.name}-controller"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
  tags               = local.base_tags
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.jenkins.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "jenkins_perms" {
  statement {
    sid       = "EcrAuth"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid = "EcrAppRW"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:PutImage",
      "ecr:DescribeImages",
      "ecr:ListImages",
    ]
    resources = [var.ecr_app_repository_arn]
  }

  statement {
    sid = "EcrJenkinsControllerRO"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
    ]
    resources = [var.ecr_jenkins_repository_arn]
  }

  statement {
    sid = "EcsDeploy"
    actions = [
      "ecs:DescribeServices",
      "ecs:UpdateService",
      "ecs:DescribeTaskDefinition",
      "ecs:RegisterTaskDefinition",
      "ecs:ListTaskDefinitions",
      "ecs:DescribeTasks",
      "ecs:ListTasks",
    ]
    resources = ["*"] # ECS describe/list/register-task-definition don't support resource-level scoping
  }

  # iam:PassRole limited to the task roles ECS will assume
  statement {
    sid       = "PassEcsTaskRoles"
    actions   = ["iam:PassRole"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_policy" "jenkins" {
  name   = "${var.name}-controller"
  policy = data.aws_iam_policy_document.jenkins_perms.json
  tags   = local.base_tags
}

resource "aws_iam_role_policy_attachment" "jenkins" {
  role       = aws_iam_role.jenkins.name
  policy_arn = aws_iam_policy.jenkins.arn
}

resource "aws_iam_instance_profile" "jenkins" {
  name = "${var.name}-controller"
  role = aws_iam_role.jenkins.name
  tags = local.base_tags
}

# --- User data: install Docker, log in to ECR, run Jenkins controller ------

locals {
  user_data = base64encode(<<-EOT
    #!/bin/bash
    set -euo pipefail
    exec > >(tee -a /var/log/user-data.log) 2>&1

    dnf update -y
    dnf install -y docker amazon-cloudwatch-agent
    systemctl enable --now docker
    usermod -aG docker ec2-user

    REGISTRY="$(echo ${var.jenkins_image} | cut -d/ -f1)"
    aws ecr get-login-password --region ${var.region} \
      | docker login --username AWS --password-stdin "$REGISTRY"

    # JENKINS_HOME on the data volume — wait for attach before scanning
    DATA_DEV=""
    for i in $(seq 1 30); do
      DATA_DEV=$(lsblk -dnpro NAME,SIZE,MOUNTPOINT,TYPE \
        | awk '$3=="" && $4=="disk" && $1!~/nvme0n1$/ {print $1; exit}')
      [ -n "$DATA_DEV" ] && break
      sleep 3
    done
    if [ -z "$DATA_DEV" ]; then
      echo "FATAL: data volume never attached" >&2
      exit 1
    fi
    if ! blkid "$DATA_DEV" >/dev/null 2>&1; then mkfs -t xfs "$DATA_DEV"; fi
    mkdir -p /var/jenkins_home
    mountpoint -q /var/jenkins_home || mount "$DATA_DEV" /var/jenkins_home
    grep -q "$DATA_DEV" /etc/fstab || echo "$DATA_DEV /var/jenkins_home xfs defaults,nofail 0 2" >> /etc/fstab
    chown -R 1000:1000 /var/jenkins_home

    # CloudWatch agent — ship system logs
    cat > /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json <<'CWJSON'
    {
      "logs": {
        "logs_collected": {
          "files": {
            "collect_list": [
              { "file_path": "/var/log/user-data.log",
                "log_group_name": "/jenkins/userdata",
                "log_stream_name": "{instance_id}" },
              { "file_path": "/var/log/jenkins.log",
                "log_group_name": "/jenkins/controller",
                "log_stream_name": "{instance_id}" }
            ]
          }
        }
      }
    }
    CWJSON
    systemctl enable --now amazon-cloudwatch-agent

    # Jenkins env (consumed by JCasC)
    mkdir -p /etc/jenkins
    cat > /etc/jenkins/casc.env <<EOF
    JENKINS_URL=http://$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4):8080/
    JENKINS_ADMIN_ID=${var.jenkins_admin_user}
    JENKINS_ADMIN_PASSWORD=${var.jenkins_admin_password}
    AWS_REGION=${var.region}
    ECR_REPOSITORY=${var.ecr_app_repository_url}
    ECS_CLUSTER=${var.ecs_cluster_name}
    ECS_SERVICE=${var.ecs_service_name}
    ECS_TASK_FAMILY=${var.ecs_task_family}
    REPO_URL=${var.repo_url}
    REPO_BRANCH=${var.repo_branch}
    EOF
    chmod 600 /etc/jenkins/casc.env

    # Resolve the host's docker group GID so the in-container jenkins user
    # can talk to /var/run/docker.sock (mounted from host)
    DOCKER_GID=$(getent group docker | cut -d: -f3)

    cat > /etc/systemd/system/jenkins.service <<'UNIT'
    [Unit]
    Description=Jenkins controller (Docker)
    After=docker.service network-online.target
    Requires=docker.service

    [Service]
    Restart=always
    RestartSec=5
    StandardOutput=append:/var/log/jenkins.log
    StandardError=inherit
    ExecStartPre=-/usr/bin/docker rm -f jenkins
    ExecStart=/usr/bin/docker run --rm --name jenkins \
      -p 8080:8080 -p 50000:50000 \
      --group-add DOCKER_GID_PLACEHOLDER \
      -v /var/jenkins_home:/var/jenkins_home \
      -v /var/run/docker.sock:/var/run/docker.sock \
      --env-file /etc/jenkins/casc.env \
      JENKINS_IMAGE_PLACEHOLDER
    ExecStop=/usr/bin/docker stop -t 60 jenkins

    [Install]
    WantedBy=multi-user.target
    UNIT

    sed -i "s|JENKINS_IMAGE_PLACEHOLDER|${var.jenkins_image}|" /etc/systemd/system/jenkins.service
    sed -i "s|DOCKER_GID_PLACEHOLDER|$DOCKER_GID|" /etc/systemd/system/jenkins.service
    systemctl daemon-reload
    systemctl enable --now jenkins
  EOT
  )
}

# --- EBS volume for JENKINS_HOME --------------------------------------------

resource "aws_ebs_volume" "jenkins_home" {
  availability_zone = data.aws_subnet.this.availability_zone
  size              = var.jenkins_volume_size
  type              = "gp3"
  encrypted         = true

  tags = merge(local.base_tags, { Name = "${var.name}-home" })
}

data "aws_subnet" "this" {
  id = var.subnet_id
}

# --- EC2 instance -----------------------------------------------------------

resource "aws_instance" "jenkins" {
  ami                    = data.aws_ssm_parameter.al2023.value
  instance_type          = var.instance_type
  subnet_id              = var.subnet_id
  iam_instance_profile   = aws_iam_instance_profile.jenkins.name
  key_name               = var.key_name
  vpc_security_group_ids = [aws_security_group.jenkins.id]
  user_data_base64       = local.user_data

  metadata_options {
    http_tokens                 = "required"
    http_endpoint               = "enabled"
    http_put_response_hop_limit = 2
  }

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
    encrypted   = true
  }

  tags = merge(local.base_tags, { Name = var.name })
}

resource "aws_volume_attachment" "jenkins_home" {
  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.jenkins_home.id
  instance_id = aws_instance.jenkins.id
}

output "jenkins_url" {
  value = "http://${aws_instance.jenkins.public_ip}:8080/"
}

output "jenkins_public_ip" {
  value = aws_instance.jenkins.public_ip
}

output "jenkins_role_name" {
  value = aws_iam_role.jenkins.name
}
