output "alb_url" {
  description = "Public URL of the application."
  value       = "http://${module.alb.alb_dns_name}"
}

output "ecr_app_repository_url" {
  description = "ECR repo URI to push app images to (matches Jenkins ECR_REPOSITORY env)."
  value       = module.ecr_app.repository_url
}

output "ecr_jenkins_repository_url" {
  description = "ECR repo URI to push the Jenkins controller image to."
  value       = module.ecr_jenkins.repository_url
}

output "ecs_cluster_name" {
  value = module.ecs_cluster.cluster_name
}

output "ecs_service_name" {
  value = module.ecs_service.service_name
}

output "ecs_task_family" {
  value = module.ecs_service.task_family
}

output "jenkins_url" {
  description = "Jenkins web UI."
  value       = module.jenkins.jenkins_url
}

output "dashboard_name" {
  value = module.monitoring.dashboard_name
}

output "alarm_topic_arn" {
  value = module.monitoring.alarm_topic_arn
}
