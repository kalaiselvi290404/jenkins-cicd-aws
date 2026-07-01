# Project 2 — Jenkins CI/CD → Containerized App on AWS (FULL SCOPE)

## Goal
A Flask API, built and tested by Jenkins on every git push (via GitHub webhook),
containerized with Docker, pushed to Amazon ECR, and deployed with a ZERO-DOWNTIME
ROLLING deploy (Ansible, one host at a time) across 2+ EC2 instances behind an
Application Load Balancer. All infrastructure provisioned with Terraform.

This is the full, uncut version — no shortcuts. Portfolio centerpiece.

## Stack
- App: Python Flask + gunicorn — `/` and `/health` routes
- Test: pytest (runs BEFORE the image is built)
- CI: Jenkins on its own dedicated EC2 box, triggered by a GitHub webhook
- Registry: Amazon ECR (immutable tags = git SHA)
- Deploy target: 2+ EC2 instances behind an ALB, across 2 AZs
- Deploy mechanism: Ansible rolling deploy (serial:1, health-checked)
- Infra: Terraform (VPC, subnets, ALB, EC2, ECR, IAM roles, security groups)

## Repo layout
```
jenkins-cicd-aws/
├── app/            app.py, requirements.txt, test_app.py
├── Dockerfile
├── Jenkinsfile
├── ansible/        deploy.yml, inventory.aws_ec2.yml, requirements.yml
├── terraform/      main, network, security, iam, compute, outputs
├── docs/           architecture.svg
└── README.md
```

## Pipeline stages (Jenkinsfile)
Checkout → Test → Build image → Push to ECR → Rolling deploy (Ansible) → Verify

## Security model (this IS a talking point)
- Jenkins box: IAM *instance role* with ECR push. No stored AWS keys.
- App instances: IAM instance role with ECR read-only.
- App port (5000) reachable ONLY from the ALB security group.
- SSH + Jenkins UI locked to my IP.

## Conventions
- Immutable image tags (git short SHA) — never `latest` in the deploy path
- Comment every file's purpose — interviewers will read this
- Explain, don't just implement

## Hard constraints — IMPORTANT
- PAUSE and show me the exact command BEFORE:
  - any `terraform apply` or `terraform destroy`
  - any AWS resource creation
  - any `docker push`
- After showing it, wait for my explicit "yes" before running.
- Do NOT add auto-scaling or CloudWatch alarms — that is Project 3. This project
  stops at a fixed fleet of 2+ instances behind the ALB.

## Cleanup reminder
- Everything is Terraform-managed, so teardown is `terraform destroy`.
- At the end of each day, remind me what is still running and billing
  (2x app t3.micro + 1x jenkins t3.small + ALB all cost money hourly).

## Interview talking points this project must support
1. "Tests run before the image is built — broken code can't reach the fleet."
2. "IAM instance roles, not long-lived keys — nothing sensitive in Jenkins."
3. "Ansible rolls the deploy one host at a time behind the ALB, so there's
    zero downtime and an automatic fallback: if a host won't go healthy, the
    deploy halts and the old version keeps serving."
