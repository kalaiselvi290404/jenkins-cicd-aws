# Jenkins CI/CD → Containerized App on AWS

A complete CI/CD pipeline that takes a commit from `git push` to a **zero-downtime
rolling deployment** across a multi-AZ fleet of EC2 instances behind an
Application Load Balancer — all infrastructure defined in Terraform.

## What it does

On every push to `main`, a GitHub webhook triggers a Jenkins pipeline that:

1. **Checks out** the code
2. **Runs the tests** — if they fail, the pipeline stops and no image is built
3. **Builds** a Docker image tagged with the git SHA
4. **Pushes** it to Amazon ECR (using an IAM instance role, no stored keys)
5. **Rolls out** the new image with Ansible — one host at a time, health-checked
6. **Verifies** the new version is live behind the load balancer

## Architecture

```
git push ──▶ GitHub ──webhook──▶ Jenkins (dedicated EC2, IAM role)
                                    │
                          Test ▶ Build ▶ Push ──▶ Amazon ECR
                                    │
                        Ansible rolling deploy (serial: 1, health-checked)
                                    │
                ┌───────────────────┴───────────────────┐
             app-1 (AZ-a)                            app-2 (AZ-b)
                └───────────────────┬───────────────────┘
                           Application Load Balancer ──▶ users
```

See `docs/architecture.svg` for the full diagram.

## Stack

| Layer            | Choice                                            |
|------------------|---------------------------------------------------|
| App              | Python Flask + gunicorn                           |
| CI               | Jenkins (declarative pipeline) on a dedicated EC2 |
| Trigger          | GitHub webhook                                    |
| Registry         | Amazon ECR (immutable tags)                       |
| Deploy           | Ansible rolling deploy across 2+ EC2 in 2 AZs     |
| Load balancing   | Application Load Balancer                         |
| Infrastructure   | Terraform (VPC, subnets, SGs, IAM, ALB, EC2, ECR) |

## Running it

Prerequisites: an AWS account, an EC2 key pair, Terraform, and a GitHub repo.

```bash
# 1. Provision the infrastructure
cd terraform
terraform init
terraform apply -var="key_name=YOUR_KEY" -var="my_ip_cidr=YOUR_IP/32"

# 2. Note the outputs: ALB DNS, Jenkins IP, ECR URL, app IPs
# 3. Configure the Jenkins job with the ECR URL + ALB DNS, add the webhook
# 4. Push a commit — watch it flow through to a live, rolling deploy
```

Full step-by-step in `RUNBOOK.md`.

## Design decisions worth calling out

**Tests gate the build.** The image is only built if tests pass, so broken code
physically cannot reach the fleet.

**No long-lived credentials.** The Jenkins box carries an IAM instance role that
can push to ECR; the app hosts carry a read-only role. There are no AWS access
keys stored anywhere in Jenkins.

**Zero-downtime by design.** Ansible deploys with `serial: 1` — it updates one
instance, waits for its `/health` endpoint to pass, and only then moves to the
next. Because the instances sit behind the ALB, at least one is always serving.
If a host won't come back healthy, the deploy halts and the previous version
keeps running — a built-in safety net.

**Immutable image tags.** Every image is tagged with its git SHA and ECR is set
to immutable, so a given tag always means exactly one build — no ambiguity about
what's deployed.

## Interview talking points

- *"Every push runs tests first; if they fail the image never gets built, so
  broken code can't reach the EC2 hosts."*
- *"I used IAM instance roles instead of long-lived access keys, so nothing
  sensitive lives in the pipeline configuration."*
- *"The deploy is a health-checked rolling update behind a load balancer — one
  host at a time — so there's zero downtime, and if a host won't go healthy the
  rollout stops and the old version keeps serving."*
