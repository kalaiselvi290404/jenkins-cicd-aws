# Jenkins CI/CD → Containerized App on AWS

A complete CI/CD pipeline that takes a commit from `git push` to a **zero-downtime
rolling deployment** across a multi-AZ fleet of EC2 instances behind an
Application Load Balancer — all infrastructure defined in Terraform.

## What it does

On every push to `main`, a GitHub webhook triggers a Jenkins pipeline that:

1. **Checks out** the code
2. **Runs pytest** — if any test fails the pipeline stops; no image is built
3. **Builds** a Docker image tagged with the git short SHA (never `latest`)
4. **Pushes** it to Amazon ECR using an IAM instance role — no stored credentials
5. **Rolls out** the new image with Ansible — one host at a time, health-checked
6. **Verifies** the ALB is serving the new version before the pipeline exits

## Architecture

```
git push ──▶ GitHub ──webhook──▶ Jenkins EC2 (IAM role: ECR push + ec2:Describe)
                                      │
                            Test ▶ Build ▶ Push to ECR
                                      │
                          Ansible dynamic inventory
                          (discovers hosts by tag, uses private IPs)
                                      │
                       rolling deploy  serial: 1, max_fail_percentage: 0
                                      │
               ┌───────────────────────────────────────────┐
           app-1 (AZ ap-south-1a)             app-2 (AZ ap-south-1b)
           IAM role: ECR read-only            IAM role: ECR read-only
               └───────────────────────────────────────────┘
                                      │
                          Application Load Balancer
                            (health-checks /health)
                                      │
                                   users
```

## Stack

| Layer          | Choice                                                      |
|----------------|-------------------------------------------------------------|
| App            | Python Flask + gunicorn, `/` and `/health` routes           |
| Tests          | pytest (runs before the image is built)                     |
| CI             | Jenkins (declarative pipeline) on a dedicated t3.small EC2  |
| Trigger        | GitHub webhook → Jenkins SG open to GitHub IP ranges        |
| Registry       | Amazon ECR, immutable tags (git short SHA)                  |
| Deploy         | Ansible rolling deploy, `serial: 1`, health-checked         |
| Load balancing | Application Load Balancer across 2 public subnets / 2 AZs  |
| Infrastructure | Terraform — VPC, subnets, IGW, SGs, IAM roles, ALB, ECR    |

## Repo layout

```
jenkins-cicd-aws/
├── app/
│   ├── app.py              Flask app — / and /health routes
│   ├── requirements.txt
│   └── test_app.py         pytest suite
├── Dockerfile
├── Jenkinsfile             Declarative pipeline (6 stages)
├── ansible/
│   ├── deploy.yml          Rolling deploy playbook
│   ├── inventory.aws_ec2.yml  Dynamic inventory (discovers by tag)
│   └── requirements.yml
├── ansible.cfg
├── terraform/
│   ├── main.tf
│   ├── network.tf          VPC, subnets, IGW, route tables
│   ├── security.tf         Security groups
│   ├── iam.tf              Instance roles (no stored keys)
│   ├── compute.tf          EC2 instances + ECR repo
│   └── outputs.tf
└── docs/
    ├── architecture.svg
    └── NOTES.md            Engineering decisions and issues solved
```

## Prerequisites

- AWS account with programmatic access (Terraform uses your local credentials)
- EC2 key pair created in `ap-south-1`
- Terraform >= 1.5
- Ansible + `amazon.aws` collection (`ansible-galaxy collection install amazon.aws`)
- Python 3 + boto3/botocore (for the dynamic inventory plugin)

## Setup

```bash
# 1. Clone and enter the repo
git clone https://github.com/kalaiselvi290404/jenkins-cicd-aws.git
cd jenkins-cicd-aws

# 2. Create terraform.tfvars (gitignored — never committed)
cat > terraform/terraform.tfvars <<EOF
key_name   = "your-key-pair-name"
my_ip_cidr = "YOUR.PUBLIC.IP/32"
EOF

# 3. Provision all infrastructure (~3 minutes)
cd terraform
terraform init
terraform apply

# 4. Note the outputs
terraform output
# alb_dns_name       = "..."
# app_instance_ips   = ["...", "..."]
# ecr_repository_url = "..."
# jenkins_public_ip  = "..."

# 5. Fill in Jenkinsfile environment variables with the ECR URL and ALB DNS
# ECR_REGISTRY = '<account>.dkr.ecr.<region>.amazonaws.com'
# ECR_REPO     = 'kalaiselvi-cicd-app'
# ALB_DNS      = '<alb-dns>.elb.amazonaws.com'

# 6. Install Jenkins on the Jenkins EC2, create the pipeline job
#    (Pipeline script from SCM → Git → your repo → branch main → Jenkinsfile)

# 7. Copy your .pem key to Jenkins for Ansible SSH
#    scp -i key.pem key.pem ubuntu@<jenkins-ip>:/var/lib/jenkins/.ssh/
#    (chmod 600, chown jenkins:jenkins)

# 8. In your GitHub repo settings, add a webhook:
#    Payload URL: http://<jenkins-ip>:8080/github-webhook/
#    Content type: application/json
#    Events: push only

# 9. Push a commit and watch the pipeline run end-to-end
git commit --allow-empty -m "trigger first webhook build"
git push origin main
```

## Pipeline stages

| Stage | What happens |
|---|---|
| Checkout | Jenkins clones the repo at the pushed SHA |
| Test | `pytest app/` — failure here stops the pipeline |
| Build image | `docker build` tagged `<ECR_REGISTRY>/<ECR_REPO>:<git-sha>` |
| Push to ECR | `aws ecr get-login-password` → `docker push` via IAM instance role |
| Rolling deploy | Ansible discovers app hosts by tag, deploys one at a time |
| Verify | `curl /health` through the ALB confirms the new version is live |

## Design decisions worth calling out

**Tests gate the build.** pytest runs before a single Docker layer is built. A
failing test means the image is never created and the fleet is never touched.
Broken code physically cannot reach production.

**No long-lived credentials.** The Jenkins EC2 carries an IAM instance role
scoped to ECR push and `ec2:DescribeInstances`. The app instances carry a
read-only ECR role. There are no AWS access keys stored anywhere in Jenkins,
no secrets in environment variables, no credentials files on disk.

**Zero-downtime by design.** Ansible deploys with `serial: 1` and
`max_fail_percentage: 0`. It pulls the new image on one instance, stops the old
container, starts the new one, and polls `/health` until it passes — only then
does it move to the next host. The ALB is always routing to at least one healthy
instance. If a host won't come back healthy, the deploy halts and the old
version keeps serving on the remaining hosts.

**Immutable image tags.** Every image is tagged with its git short SHA. ECR
is configured with `image_tag_mutability = "IMMUTABLE"`, so a given tag always
means exactly one build — no ambiguity, no silent overwrites, clear audit trail.

## Interview talking points

- *"Every push runs tests first. If they fail, the image is never built, so
  broken code can't reach the EC2 fleet."*

- *"I used IAM instance roles for both the Jenkins box and the app instances —
  Jenkins can push to ECR, the apps can pull. No access keys are stored
  anywhere in the pipeline."*

- *"The Ansible deploy uses `serial: 1` behind a load balancer. It updates one
  host, waits for the health check to pass, then moves to the next. There's
  always at least one host serving the old version until the new one is proven
  healthy — zero downtime, and the rollout stops automatically if something
  goes wrong."*

## Teardown

Everything is Terraform-managed:

```bash
cd terraform
terraform destroy
```

This removes all AWS resources: EC2 instances, ALB, ECR repo, VPC, IAM roles,
and security groups. Nothing is left running or billing after destroy completes.
