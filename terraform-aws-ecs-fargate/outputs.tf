################################################
#                   Outputs                    #
################################################
# Identifiers and addresses only: outputs land in the state file.

output "app_url" {
  description = "Application URL"
  value       = "http://${aws_lb.main.dns_name}"
}

output "ecr_repository_url" {
  description = "Where to push the image"
  value       = aws_ecr_repository.app.repository_url
}

# Full sequence: registry login, build, push, rollout.
output "push_commands" {
  description = "Build and push the image"
  value       = <<-EOT
    aws ecr get-login-password --region ${var.region} | docker login --username AWS --password-stdin ${aws_ecr_repository.app.repository_url}
    docker build -t ${aws_ecr_repository.app.repository_url}:${var.image_tag} .
    docker push ${aws_ecr_repository.app.repository_url}:${var.image_tag}
    aws ecs update-service --cluster ${aws_ecs_cluster.main.name} --service ${aws_ecs_service.app.name} --force-new-deployment --region ${var.region}
  EOT
}

output "ecs_cluster_name" {
  description = "Cluster name"
  value       = aws_ecs_cluster.main.name
}

output "ecs_service_name" {
  description = "Service name"
  value       = aws_ecs_service.app.name
}

output "log_group" {
  description = "Where task logs go"
  value       = aws_cloudwatch_log_group.app.name
}

output "db_endpoint" {
  description = "Database endpoint inside the VPC"
  value       = aws_db_instance.main.endpoint
}

output "db_secret_arn" {
  description = "Database master password secret: the ARN, not the value"
  value       = aws_db_instance.main.master_user_secret[0].secret_arn
}
