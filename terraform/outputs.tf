# The values you'll need after `terraform apply` — feed these into Jenkins,
# the browser, and your verification checks.

output "alb_dns_name" {
  description = "Public URL of the app — visit http://<this>/ and /health"
  value       = aws_lb.app.dns_name
}

output "jenkins_public_ip" {
  description = "Jenkins UI at http://<this>:8080 and SSH target"
  value       = aws_instance.jenkins.public_ip
}

output "ecr_repository_url" {
  description = "Set this as ECR_REGISTRY/ECR_REPO in the Jenkinsfile"
  value       = aws_ecr_repository.app.repository_url
}

output "app_instance_ips" {
  description = "Public IPs of the app instances (Ansible reaches these)"
  value       = aws_instance.app[*].public_ip
}
