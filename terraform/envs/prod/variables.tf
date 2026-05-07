variable "region" {
  type    = string
  default = "us-east-1"
}

variable "project" {
  type    = string
  default = "assessment"
}

variable "environment" {
  type    = string
  default = "prod"
}

# --- Networking -------------------------------------------------------------

variable "vpc_cidr" {
  type    = string
  default = "10.40.0.0/16"
}

variable "azs" {
  type    = list(string)
  default = ["us-east-1a", "us-east-1b"]
}

# --- ECS hosts --------------------------------------------------------------

variable "ecs_instance_type" {
  type    = string
  default = "t3.small"
}

variable "ecs_asg_desired" {
  type    = number
  default = 2
}

variable "ecs_asg_min" {
  type    = number
  default = 1
}

variable "ecs_asg_max" {
  type    = number
  default = 4
}

# --- App task ---------------------------------------------------------------

variable "app_desired_count" {
  type    = number
  default = 2
}

variable "app_cpu" {
  type    = number
  default = 256
}

variable "app_memory" {
  type    = number
  default = 384
}

variable "app_container_port" {
  type    = number
  default = 3000
}

variable "app_initial_image" {
  description = "Placeholder image used to seed the task definition before the first pipeline run; Jenkins overwrites this on every deploy."
  type        = string
  default     = "public.ecr.aws/nginx/nginx:stable-alpine"
}

# --- Jenkins ----------------------------------------------------------------

variable "jenkins_admin_cidr" {
  description = "CIDR allowed to reach Jenkins UI/SSH."
  type        = string
}

variable "jenkins_key_name" {
  description = "Existing EC2 key pair for SSH (optional)."
  type        = string
  default     = null
}

variable "jenkins_admin_password" {
  description = "Initial Jenkins admin password."
  type        = string
  sensitive   = true
}

variable "jenkins_image" {
  description = "Full image URI of the custom Jenkins controller in ECR "
  type        = string
}

variable "jenkins_instance_type" {
  type    = string
  default = "t3.micro"
}

variable "repo_url" {
  description = "Git URL the Jenkins job clones (e.g. https://github.com/you/assessment.git)."
  type        = string
}

variable "repo_branch" {
  type    = string
  default = "main"
}

# --- Observability ----------------------------------------------------------

variable "alarm_email" {
  description = "Email address subscribed to the alarm SNS topic. Empty disables."
  type        = string
  default     = ""
}

variable "log_retention_days" {
  type    = number
  default = 30
}
