# Interview Prep — Jenkins CI/CD on AWS

This guide walks through every layer of the project with references to the
actual code. Use the flashcards for quick recall, the deep-dives for
explaining the "why", and the Q&A section to rehearse out loud.

---

## Project summary (say this in 30 seconds)

> "I built a full CI/CD pipeline on AWS from scratch. A Flask app is tested with
> pytest and containerised with Docker. Jenkins — on its own EC2 — is triggered
> by a GitHub webhook on every push. It runs the tests, builds a Docker image
> tagged with the git SHA, pushes it to Amazon ECR using an IAM instance role
> (no stored credentials), then uses Ansible to do a zero-downtime rolling deploy
> across two EC2 instances behind an Application Load Balancer. Every piece of
> infrastructure is provisioned with Terraform."

---

## Codebase map

```
app/app.py              Flask app — / and /health routes
app/test_app.py         pytest suite (runs BEFORE the image is built)
Dockerfile              python:3.12-slim + gunicorn
Jenkinsfile             6-stage declarative pipeline
ansible/deploy.yml      Rolling deploy playbook (serial: 1)
ansible/inventory...yml Dynamic inventory (discovers hosts by EC2 tag)
ansible.cfg             SSH config for Jenkins → app instances
terraform/iam.tf        IAM instance roles — the "no keys" story
terraform/security.tf   Security groups — traffic path in code
terraform/compute.tf    EC2 instances, ECR repo
terraform/network.tf    VPC, subnets, IGW, route tables
terraform/outputs.tf    Jenkins IP, ALB DNS, ECR URL, app IPs
```

---

## Deep dives by component

### 1. The Flask app (`app/app.py`)

```python
APP_VERSION = os.environ.get("APP_VERSION", "dev")

@app.route("/health")
def health():
    return jsonify(status="healthy", version=APP_VERSION), 200
```

**Why it matters:**
- `/health` is polled by both the ALB (target group health check) and Ansible
  (after each container restart). It is cheap and dependency-free on purpose —
  no database call, no external dependency, so it never gives a false negative.
- `APP_VERSION` is injected at Docker build time as `--build-arg APP_VERSION=<git-sha>`.
  This means you can `curl /health` through the ALB during a rolling deploy and
  watch the version flip from the old SHA to the new one, host by host.

---

### 2. The test suite (`app/test_app.py`)

```python
def test_health_returns_healthy():
    res = _client().get("/health")
    assert res.status_code == 200
    data = res.get_json()
    assert data["status"] == "healthy"
```

**Why it matters:**
- These run in the `Test` stage of the Jenkinsfile, BEFORE `docker build` is
  even called. If either test fails, Jenkins exits and the Docker daemon is
  never touched. Broken code literally cannot be packaged.
- The client is Flask's built-in test client — no network, no Docker, no AWS.
  Fast and self-contained.

---

### 3. The Dockerfile

```dockerfile
FROM python:3.12-slim
ENV PYTHONUNBUFFERED=1
WORKDIR /app
COPY app/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt gunicorn==22.0.0
COPY app/ .
ARG APP_VERSION=dev
ENV APP_VERSION=${APP_VERSION}
EXPOSE 5000
CMD ["gunicorn", "--bind", "0.0.0.0:5000", "--workers", "2", "app:app"]
```

**Key points:**
- `python:3.12-slim` — slim keeps the image small; avoids the full Debian install.
- `requirements.txt` is copied and installed BEFORE `app/` is copied. This is a
  layer caching trick — if only the app code changes (not requirements), Docker
  reuses the cached pip layer and the build is fast.
- `gunicorn` not Flask's dev server — gunicorn is a production WSGI server that
  handles concurrent requests properly. Flask's `app.run()` is single-threaded.
- `ARG APP_VERSION` → `ENV APP_VERSION` — the build-time arg becomes a runtime
  environment variable so Flask can read it.

---

### 4. The Jenkinsfile

```groovy
IMAGE_TAG = "${env.GIT_COMMIT?.take(7) ?: 'manual'}"
IMAGE_URI = "${ECR_REGISTRY}/${ECR_REPO}:${IMAGE_TAG}"
```

The `?.take(7)` is Groovy's null-safe call — if `GIT_COMMIT` is null (manual
trigger with no SCM), it falls back to `'manual'`. Otherwise it slices to 7
characters (standard short SHA).

**The 6 stages and what to say about each:**

| Stage | What it does | Talking point |
|---|---|---|
| Checkout | `checkout scm` | Jenkins uses the same SHA the webhook reported |
| Test | pytest in a venv | Failure here stops the pipeline — image never built |
| Build image | `docker build --build-arg APP_VERSION=${IMAGE_TAG}` | SHA baked into the image at build time |
| Push to ECR | `aws ecr get-login-password \| docker login` | No stored credentials — IAM role on the EC2 provides them |
| Rolling deploy | `ansible-playbook -i inventory.aws_ec2.yml deploy.yml` | One host at a time, health-checked |
| Verify | `curl /health` through the ALB | Confirms the ALB is routing to the new version |

**`disableConcurrentBuilds()`** — if two pushes land quickly, Jenkins queues
them. Two pipeline runs cannot race each other and deploy out of order.

---

### 5. IAM roles (`terraform/iam.tf`)

```hcl
# Jenkins role: ECR push + discover EC2 hosts
resource "aws_iam_role_policy_attachment" "jenkins_ecr_power" {
  role       = aws_iam_role.jenkins.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPowerUser"
}

resource "aws_iam_role_policy" "jenkins_ec2_describe" {
  policy = jsonencode({
    Statement = [{
      Effect   = "Allow"
      Action   = ["ec2:DescribeInstances", "ec2:DescribeTags"]
      Resource = "*"
    }]
  })
}

# App role: ECR pull only
resource "aws_iam_role_policy_attachment" "app_ecr_read" {
  role       = aws_iam_role.app.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}
```

**The full story to tell:**
- An IAM instance role is attached to the EC2 at launch. The AWS CLI on the
  instance calls the EC2 metadata service (`169.254.169.254`) to get short-lived
  temporary credentials. These rotate automatically — no expiry to manage.
- Jenkins has `ECRPowerUser` (push) and `ec2:Describe*` (for Ansible to find hosts).
- App instances have `ECRReadOnly` (pull the image they were just told to run).
- Neither role has an access key or secret. There is nothing to leak, rotate, or
  accidentally commit to git.

---

### 6. Ansible dynamic inventory (`ansible/inventory.aws_ec2.yml`)

```yaml
plugin: amazon.aws.aws_ec2
regions:
  - ap-south-1
filters:
  tag:Role: cicd-app
  instance-state-name: running
compose:
  ansible_host: private_ip_address
```

**Why dynamic, not static:**
- A static inventory (`hosts: [13.206.94.89, 3.109.124.133]`) breaks the moment
  an instance is replaced or the fleet scales. The dynamic plugin queries the AWS
  EC2 API at deploy time and discovers every running instance tagged `Role=cicd-app`.
- `ansible_host: private_ip_address` — Ansible SSHes from the Jenkins EC2 to
  the app instances. All three are in the same VPC. AWS does not support hairpin
  NAT (intra-VPC traffic via a public IP is dropped at the IGW). Private IPs
  are required.

---

### 7. Ansible rolling deploy (`ansible/deploy.yml`)

```yaml
serial: 1
max_fail_percentage: 0

tasks:
  - name: Pull the new image
    community.docker.docker_image:
      name: "{{ image_uri }}"
      source: pull

  - name: Stop and remove the old container
    community.docker.docker_container:
      name: "{{ container_name }}"
      state: absent

  - name: Start the new container
    community.docker.docker_container:
      name: "{{ container_name }}"
      image: "{{ image_uri }}"
      state: started
      restart_policy: always
      published_ports: ["{{ app_port }}:5000"]

  - name: Wait until healthy before moving on
    ansible.builtin.uri:
      url: "http://127.0.0.1:{{ app_port }}/health"
      status_code: 200
    retries: 10
    delay: 3
    until: health.status == 200 and 'healthy' in health.content
```

**`serial: 1` means:**
- With 2 instances, Ansible updates instance A completely (pull → stop → start
  → health check passes) before touching instance B. During this window, instance
  B is still serving the old version through the ALB. Zero downtime.

**`max_fail_percentage: 0` means:**
- If the health check on instance A fails after 10 retries (30 seconds), Ansible
  stops immediately. Instance B is never touched. The old version keeps serving.
  The deploy halts rather than cascading a bad image to the whole fleet.

**ECR auth on the app instances:**
- Each app instance has its own IAM role with `ECRReadOnly`. The deploy playbook
  runs `aws ecr get-login-password` on each app host using that host's own
  instance role — not a credential passed from Jenkins.

---

### 8. Security groups (`terraform/security.tf`)

```
internet → ALB SG (port 80, 0.0.0.0/0)
             ↓
        App SG (port 5000, source: ALB SG only)
        App SG (port 22, source: your IP)
        App SG (port 22, source: Jenkins SG)   ← Ansible SSH
             ↓
      Jenkins SG (port 8080, source: your IP + GitHub IP ranges)
      Jenkins SG (port 22, source: your IP)
```

**Key design choices:**
- App instances accept traffic on port 5000 **only from the ALB security group**
  — not from `0.0.0.0/0`. Even if someone knows the instance's public IP, they
  cannot reach the app directly.
- Jenkins accepts port 8080 from GitHub's published webhook IP ranges
  (`192.30.252.0/22`, `185.199.108.0/22`, `140.82.112.0/20`, `143.55.64.0/20`
  plus IPv6). No tunnel or relay needed.
- SSH on both instance types is restricted to your IP only, except for
  Jenkins→app SSH which uses a security group reference (not an IP).

---

## Flashcards

Read the question, say the answer aloud, then flip.

---

**Q: What is an IAM instance role and why is it better than storing access keys?**

A: An IAM role attached to an EC2 instance. The AWS SDK/CLI on the instance
automatically fetches short-lived temporary credentials from the instance metadata
service. You never create, store, rotate, or potentially leak a static access key.
If the instance is compromised, the credentials expire on their own and cannot be
reused elsewhere.

---

**Q: Why do tests run before `docker build` in this pipeline?**

A: The `Test` stage in the Jenkinsfile runs pytest inside a virtualenv. If any
test fails, Jenkins exits with a non-zero code and the pipeline stops. The
`Build image` stage never runs. The Docker image is never created, ECR is never
touched, and the fleet is never contacted. Broken code cannot physically reach
production.

---

**Q: What does `serial: 1` do in the Ansible playbook?**

A: Ansible processes the host list one at a time instead of in parallel. It
completes the full task list (pull → stop → start → health check) on the first
host before touching the second. With two instances behind an ALB, one is always
serving the old version while the other is being updated.

---

**Q: What does `max_fail_percentage: 0` do?**

A: If any single host fails its health check after all retries, Ansible stops
the entire play. It does not move on to remaining hosts. This means a bad image
can take down one instance but can never propagate to the whole fleet. The old
version keeps serving on untouched hosts.

---

**Q: Why does the Ansible inventory use `private_ip_address` instead of `public_ip_address`?**

A: All three EC2 instances (Jenkins + 2 app) are in the same VPC. AWS VPC does
not support hairpin NAT — a packet sent from inside the VPC to an instance's
public Elastic IP is dropped at the internet gateway rather than looped back
internally. The private IPs route directly within the VPC with no IGW involved.

---

**Q: What is an immutable ECR image tag and why use it?**

A: ECR `image_tag_mutability = "IMMUTABLE"` prevents a tag from being
overwritten by a new push. Combined with git-SHA tags (e.g., `fa5f8b0`), every
tag permanently identifies exactly one build. You can always trace a running
container back to its source commit, and you can never accidentally deploy the
wrong build by reusing a tag.

---

**Q: How does Jenkins authenticate to ECR without storing AWS credentials?**

A: The Jenkins EC2 has an IAM instance role with `ECRPowerUser` attached. In the
`Push to ECR` stage, the pipeline runs:
```sh
aws ecr get-login-password --region ap-south-1 \
  | docker login --username AWS --password-stdin <registry>
```
The AWS CLI fetches a temporary ECR token using the instance role credentials
from the metadata service. No key is stored in Jenkins, no credential binding
is needed.

---

**Q: How does the webhook trigger work?**

A: GitHub's webhook settings send an HTTP POST to
`http://<jenkins-ip>:8080/github-webhook/` on every push to main. The Jenkins
security group allows inbound port 8080 from GitHub's published IP ranges
(`api.github.com/meta` → `hooks` key). Jenkins' GitHub plugin receives the
payload and schedules a build for the matching pipeline job.

---

**Q: What does `disableConcurrentBuilds()` in the Jenkinsfile do?**

A: Prevents two pipeline runs from executing at the same time. If a second push
arrives while a build is running, Jenkins queues it. This ensures deploys happen
in order and two Ansible playbooks can never race each other against the same fleet.

---

**Q: Why is gunicorn used instead of Flask's built-in server?**

A: Flask's `app.run()` is a single-threaded development server — it handles one
request at a time and is not safe for production. Gunicorn is a pre-fork WSGI
server that spawns multiple worker processes (2 in this project) and handles
concurrent requests properly. It is the standard way to run Flask in production.

---

**Q: What is Terraform's role in this project?**

A: Terraform provisions and manages all AWS infrastructure: VPC, public subnets
across two AZs, internet gateway, route tables, security groups, IAM roles and
instance profiles, EC2 instances, Application Load Balancer, target group, ALB
listener, and the ECR repository. Every resource is declared in `.tf` files and
version-controlled. `terraform destroy` tears down everything cleanly.

---

**Q: How does the `Verify` stage confirm the deploy worked?**

A: After Ansible finishes, the pipeline runs a loop that `curl`s
`http://<ALB_DNS>/health` up to 10 times (60 seconds total). It greps the
response for `"version":"<git-sha>"`. Because the app returns its build SHA in
the health endpoint, a match confirms the ALB is routing to the new version on
at least one host.

---

**Q: What is the traffic path from a user's browser to the Flask app?**

A: Browser → ALB (port 80, open to internet) → target group health check passes
→ ALB forwards to an app instance on port 5000 → app SG allows port 5000 only
from the ALB SG → gunicorn on the instance handles the request → Flask returns
the response.

---

## Interview questions and answers

### Technical — walk-through style

**"Walk me through what happens when you run `git push origin main`."**

> GitHub receives the push and fires a webhook POST to
> `http://13.206.99.247:8080/github-webhook/`. Jenkins picks it up and starts
> the pipeline. First, pytest runs in a virtualenv — if any test fails, the
> pipeline exits and nothing else happens. If tests pass, Docker builds an image
> tagged with the 7-character git SHA and pushes it to ECR using the Jenkins
> IAM instance role. Then Ansible takes over: it queries the EC2 API to find
> all running instances tagged `Role=cicd-app`, SSHes to the first one over
> the private IP, pulls the new image, stops the old container, starts the new
> one, and polls `/health` until it returns 200. Then it does the same to the
> second instance. Finally Jenkins curls the ALB and confirms the new SHA is in
> the response. The whole thing takes about 3–4 minutes.

---

**"What happens if a deployment fails halfway through?"**

> `max_fail_percentage: 0` in the Ansible playbook means if any host's health
> check does not pass within 30 seconds (10 retries × 3 second delay), Ansible
> stops the play entirely. The second instance is never touched. So you end up
> with: instance A running the new (broken) image, instance B still running the
> old image. The ALB health check will detect that instance A is unhealthy and
> stop sending traffic to it. Instance B keeps serving the old version with no
> downtime. The pipeline exits with a failure. The fix is to push a corrected
> commit, which triggers a fresh pipeline run.

---

**"How would you roll back to a previous version?"**

> Because every image is tagged with its git SHA and ECR tags are immutable, any
> previous image is still in ECR. A rollback is just changing the `image_uri`
> to an older SHA and re-running the Ansible playbook. In practice you could
> add a Jenkins job that takes a SHA as a parameter and calls the deploy stage
> directly. The current project doesn't have a dedicated rollback job — but
> the infrastructure supports it because we never delete old images or reuse tags.

---

**"Why did you use Ansible for the deploy instead of, say, AWS CodeDeploy?"**

> Ansible gives full control over the deploy sequence with no agent required on
> the instances — it SSHes in using the same key pair already needed for EC2
> access. The `serial: 1` and `max_fail_percentage: 0` options map exactly to
> the zero-downtime rolling deploy pattern. CodeDeploy would also work, but it
> requires the CodeDeploy agent installed on every instance and ties the project
> more tightly to AWS-specific tooling. Ansible is cloud-agnostic and the
> playbook is readable without knowing any AWS-specific concepts.

---

**"How does Ansible know which EC2 instances to deploy to?"**

> The `amazon.aws.aws_ec2` dynamic inventory plugin queries the EC2 API for
> instances that are tagged `Role=cicd-app` and in the `running` state. It
> groups them under `role_cicd_app` (the `keyed_groups` config). The playbook
> targets `hosts: role_cicd_app`. Jenkins' IAM role has `ec2:DescribeInstances`
> permission so the plugin can make the API call. No IP addresses are hardcoded
> anywhere.

---

**"Port 5000 on the app instances is only reachable from the ALB. How is that enforced?"**

> In `terraform/security.tf`, the app security group's ingress rule for port 5000
> specifies `security_groups = [aws_security_group.alb.id]` as the source instead
> of a CIDR block. AWS evaluates this at the packet level — only traffic that
> originated from an ENI in the ALB security group is allowed through. If someone
> tried to hit the app instance's public IP directly on port 5000, the packet
> would be dropped by the security group before reaching the instance.

---

**"What is the VPC setup?"**

> One VPC with two public subnets, one in each availability zone (`ap-south-1a`
> and `ap-south-1b`). An internet gateway and a route table with a default route
> (`0.0.0.0/0 → IGW`) make them publicly routable. The ALB spans both subnets
> for AZ redundancy. The two app instances are placed one per subnet. Jenkins is
> in one of them. All instances get public IPs for outbound internet access
> (pulling packages, reaching ECR's public endpoint) but the security groups
> control what inbound traffic is allowed.

---

**"Why didn't you use a private subnet for the app instances?"**

> For this portfolio project, simplicity was the priority — private subnets
> require a NAT gateway (~$32/month extra) for the instances to reach the
> internet (needed to pull from ECR and install packages). The security group
> approach achieves the same security goal for the application traffic: port 5000
> is only reachable from the ALB, regardless of whether the instance has a
> public IP. In a production system with compliance requirements, private subnets
> and a NAT gateway would be the right choice.

---

### Behavioural — things that went wrong

**"Tell me about a problem you hit during this build."**

> A few worth mentioning. The most instructive was the SSH timeout from Jenkins
> to the app instances. Ansible was configured to use the public IPs for SSH.
> The Jenkins security group was allowed as a source in the app security group,
> so the firewall rule was correct. But the connections still timed out. After
> debugging, I found that AWS VPC does not support hairpin NAT — when Jenkins
> (inside the VPC) tries to SSH to an app instance via its public Elastic IP,
> the packet exits toward the internet gateway which drops it because the source
> is also inside the VPC. The fix was one line in the Ansible inventory:
> changing `ansible_host: public_ip_address` to `ansible_host: private_ip_address`.
> Private IPs route directly within the VPC. That's the kind of bug that's
> invisible from the outside — the fix looks trivial but the diagnosis requires
> understanding how AWS VPC routing actually works.

---

**"What would you add to this pipeline if you were taking it to production?"**

> Three things in priority order. First, HTTPS on the ALB — right now it's HTTP
> only. I'd add an ACM certificate and an HTTPS listener, redirect port 80 to
> 443. Second, CloudWatch alarms on the ALB's `UnHealthyHostCount` metric — if
> a deploy goes bad and an instance falls out of the target group, I want a
> notification immediately. Third, auto-scaling: right now the fleet is a fixed
> two instances. Adding an Auto Scaling Group with a target tracking policy on
> ALB request count would let the fleet grow under load and shrink during quiet
> periods. I deliberately left these out of this project because I wanted the
> CI/CD pipeline itself to be the focus, not the infrastructure scaling story.

---

### Flashcard rapid-fire (practice answering in one sentence each)

| Question | One-line answer |
|---|---|
| What runs before the Docker build? | pytest — if any test fails, the pipeline stops and no image is created |
| How does Jenkins log into ECR? | IAM instance role → `aws ecr get-login-password` → temporary token, no stored key |
| What tag is used for Docker images? | The 7-character git short SHA — immutable, traceable |
| What does `serial: 1` do in Ansible? | Updates one host completely before touching the next |
| What stops a bad deploy from taking down all hosts? | `max_fail_percentage: 0` — Ansible halts if any host fails its health check |
| Why private IPs for Ansible SSH? | AWS VPC drops intra-VPC traffic routed through a public IP (no hairpin NAT) |
| How does the ALB know a host is healthy? | It polls `/health` on port 5000 — returns `{"status":"healthy"}` with HTTP 200 |
| What Terraform resource locks app traffic to ALB only? | Security group ingress with `source = ALB security group id` instead of a CIDR |
| What's the teardown command? | `terraform destroy` — removes all AWS resources |
| How does the pipeline confirm the deploy succeeded? | Curls the ALB `/health` endpoint and checks the response contains the new git SHA |
