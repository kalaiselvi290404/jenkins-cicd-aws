# Security groups — the firewall rules that make the traffic path explicit.
# Path: internet -> ALB (80) -> app instances (5000, only from the ALB).
# SSH and the Jenkins UI are locked to your IP only.

# ---- ALB: open to the world on 80 ----
resource "aws_security_group" "alb" {
  name        = "${var.project_name}-alb-sg"
  description = "ALB - public HTTP in"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTP from anywhere"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "${var.project_name}-alb-sg" }
}

# ---- App instances: app port ONLY from the ALB; SSH only from you ----
resource "aws_security_group" "app" {
  name        = "${var.project_name}-app-sg"
  description = "App instances - traffic only from the ALB"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "App port from the ALB only"
    from_port       = 5000
    to_port         = 5000
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }
  ingress {
    description = "SSH from my IP (for debugging)"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.my_ip_cidr]
  }
  ingress {
    description     = "SSH from Jenkins for Ansible rolling deploy"
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [aws_security_group.jenkins.id]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "${var.project_name}-app-sg" }
}

# ---- Jenkins box: UI (8080) + SSH, both locked to your IP ----
resource "aws_security_group" "jenkins" {
  name        = "${var.project_name}-jenkins-sg"
  description = "Jenkins - UI and SSH from my IP; webhook from GitHub"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "Jenkins UI from my IP"
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = [var.my_ip_cidr]
  }
  ingress {
    description = "SSH from my IP"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.my_ip_cidr]
  }
  # NOTE: GitHub webhooks come from GitHub's IP ranges. For a portfolio build,
  # the simplest robust option is to open 8080 to GitHub's documented hook
  # ranges, OR use a lightweight tunnel. See RUNBOOK Phase 4 for the tradeoff.
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "${var.project_name}-jenkins-sg" }
}
