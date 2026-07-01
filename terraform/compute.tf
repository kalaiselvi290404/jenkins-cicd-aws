# ECR registry, the app instances, the Jenkins box, and the ALB that ties the
# app instances together for zero-downtime rolling deploys.

# ---- Latest Ubuntu 22.04 AMI ----
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
}

# ---- ECR repository for the app image ----
resource "aws_ecr_repository" "app" {
  name                 = "${var.project_name}-app"
  image_tag_mutability = "IMMUTABLE" # tags (git SHAs) can't be overwritten
  image_scanning_configuration {
    scan_on_push = true
  }
  tags = { Name = "${var.project_name}-ecr" }
}

# ---- Bootstrap: install docker + the AWS CLI on every box ----
locals {
  bootstrap = <<-EOF
    #!/bin/bash
    apt-get update -y
    apt-get install -y docker.io unzip
    systemctl enable --now docker
    curl -s "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o awscliv2.zip
    unzip -q awscliv2.zip && ./aws/install
  EOF
}

# ---- App instances (>=2, one per AZ) ----
resource "aws_instance" "app" {
  count                  = var.app_instance_count
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = "t3.micro"
  subnet_id              = aws_subnet.public[count.index % 2].id
  vpc_security_group_ids = [aws_security_group.app.id]
  iam_instance_profile   = aws_iam_instance_profile.app.name
  key_name               = var.key_name
  user_data              = local.bootstrap

  tags = {
    Name = "${var.project_name}-app-${count.index + 1}"
    Role = "cicd-app" # <-- Ansible dynamic inventory finds hosts by this tag
  }
}

# ---- Jenkins box ----
resource "aws_instance" "jenkins" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = "t3.small" # Jenkins wants a bit more memory
  subnet_id              = aws_subnet.public[0].id
  vpc_security_group_ids = [aws_security_group.jenkins.id]
  iam_instance_profile   = aws_iam_instance_profile.jenkins.name
  key_name               = var.key_name
  user_data              = local.bootstrap

  tags = { Name = "${var.project_name}-jenkins" }
}

# ---- Application Load Balancer ----
resource "aws_lb" "app" {
  name               = "${var.project_name}-alb"
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.public[*].id
  tags               = { Name = "${var.project_name}-alb" }
}

resource "aws_lb_target_group" "app" {
  name     = "${var.project_name}-tg"
  port     = 5000
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id

  health_check {
    path                = "/health"
    healthy_threshold   = 2
    unhealthy_threshold = 2
    interval            = 10
    timeout             = 5
    matcher             = "200"
  }
  tags = { Name = "${var.project_name}-tg" }
}

resource "aws_lb_target_group_attachment" "app" {
  count            = var.app_instance_count
  target_group_arn = aws_lb_target_group.app.arn
  target_id        = aws_instance.app[count.index].id
  port             = 5000
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.app.arn
  port              = 80
  protocol          = "HTTP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}
