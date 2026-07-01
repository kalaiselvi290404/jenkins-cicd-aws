# Project 2 Runbook — FULL SCOPE — Jenkins CI/CD → AWS with Claude Code

**Target: 2–3 focused days. This is the uncut version — webhook trigger,
dedicated Jenkins box, ALB, and zero-downtime rolling deploy.**

Keep this open beside the terminal. The `>` blocks are prompts to paste into
Claude Code. Most of the code already exists in this package — Claude Code's
job is to wire it up, run it on real AWS, and debug what breaks.

---

## Architecture at a glance

```
  git push ──▶ GitHub ──webhook──▶ Jenkins (own EC2 box, IAM role)
                                      │
                            Test ▶ Build ▶ Push image ▶ ECR
                                      │
                              Ansible rolling deploy (serial:1)
                                      │
                    ┌─────────────────┴─────────────────┐
                 app-1 (AZ-a)                        app-2 (AZ-b)
                    └─────────────────┬─────────────────┘
                                     ALB  ──▶  users
```

---

## Before you start (checklist)

- [ ] Claude Pro (or higher) — Claude Code needs a paid plan
- [ ] AWS creds working: `aws sts get-caller-identity`
- [ ] An EC2 **key pair** created in your region (you'll pass its name to Terraform)
- [ ] Your public IP (visit whatismyip.com) — for `my_ip_cidr`, format `1.2.3.4/32`
- [ ] Docker Desktop installed (for local Phase 1 testing)
- [ ] Git + a GitHub repo ready
- [ ] Terraform installed (`terraform -version`)
- [ ] Working in **PowerShell/CMD**, not Git Bash

---

## 💰 Cost guard — set this up BEFORE Phase 2 (10 min)

Her account is ~3 months old, so the 12-month Free Tier is active. That covers
**750 hours/month of t3.micro** (one instance running 24/7) + 30GB EBS. What is
NOT free: the second t3.micro beyond 750 hrs, the Jenkins **t3.small**, and the
**ALB** (~$0.0225/hr — the main cost driver).

**Real cost of this build, if torn down after each session:**
- One 8-hr build day: **under ₹50 (<$1)**
- Full 3-day build, ~24 hrs total: **~₹120–150 (~$1.50–2)**
- ⚠️ Left running a whole month by accident: **~$35–40 (~₹3,000)**

The entire risk is forgetting to tear down. Two safety nets:

**1. Set a billing alarm (do this first, once):**
> Help me create an AWS Budgets alarm that emails me if my spend crosses $5
> this month. Show me the console steps or the CLI command.

**2. Confirm Free Tier is active:**
AWS Console → Billing → Free Tier — you should see t3.micro usage tracking there
after Phase 2.

**The hard rule:** at the end of EVERY session, run `terraform destroy`. Rebuild
is ~10 min next time. Never leave the ALB + fleet running overnight "to save
setup time" — the setup time is cheaper than the bill.

- [ ] $5 billing alarm set
- [ ] Free Tier confirmed active in the Billing console

---

## DAY 1 — App, container, and infrastructure

### Phase 0 — Claude Code setup · ⏱ 30 min
```powershell
irm https://claude.ai/install.ps1 | iex
```
Close terminal, open a NEW PowerShell window, then:
```powershell
claude --version
cd jenkins-cicd-aws      # the folder containing this package
claude
```
Inside: run `/init`, then replace CLAUDE.md with the one in this package.

### Phase 1 — App green locally · ⏱ 45 min
> Build the Docker image and run the pytest suite locally to confirm both are
> green before we touch AWS. Then run the container and curl /health.

- [ ] `pytest` passes · [ ] image builds · [ ] `/health` responds locally

### Phase 2 — Terraform infrastructure · ⏱ 2–3 hrs ⚠️ MONEY STARTS HERE
> Walk me through the Terraform in terraform/. Run `terraform init` and
> `terraform validate` first. Then `terraform plan` — show me the full plan and
> PAUSE. Do not apply until I say yes. I'll pass key_name and my_ip_cidr.

After you approve `apply`, capture the outputs (ALB DNS, Jenkins IP, ECR URL,
app IPs).

- [ ] `terraform validate` clean
- [ ] plan reviewed and approved by you
- [ ] apply complete, outputs saved
- [ ] ECR repo, ALB, 2 app instances, Jenkins box all exist

*End Day 1 here. If you want to stop billing overnight, note that `terraform
destroy` tears it ALL down, but you'll rebuild tomorrow (~10 min). For a 2–3 day
run it's usually fine to leave a t3.micro fleet up — but decide consciously.*

---

## DAY 2 — Jenkins, ECR, and the pipeline

### Phase 3 — Jenkins on its EC2 box · ⏱ 2 hrs
> SSH to the Jenkins instance. Install Jenkins, Docker access for the jenkins
> user, the AWS CLI, Ansible, and the Ansible collections from
> ansible/requirements.yml. Then walk me through the first-run unlock and
> installing the GitHub + Pipeline plugins.

- [ ] Jenkins UI reachable at `http://<jenkins-ip>:8080` (from your IP)
- [ ] jenkins user can run docker
- [ ] ansible + collections installed on the box

### Phase 4 — Webhook + pipeline green to ECR · ⏱ 2–3 hrs ⚠️ THE HARD PART
> Create a Pipeline job pointed at my GitHub repo using the Jenkinsfile. Fill
> ECR_REGISTRY/ECR_REPO and ALB_DNS from the Terraform outputs. Configure the
> GitHub webhook so a push triggers the build. Run it and get everything green
> through the Push-to-ECR stage (deploy stage next phase).

**Webhook reality:** GitHub must reach Jenkins on 8080. Two options — ask Claude
Code to help pick:
- Open 8080 to GitHub's published hook IP ranges (edit the jenkins SG), or
- Use a tunnel (e.g. ngrok/smee) for the demo and document it.

- [ ] push to GitHub auto-triggers the pipeline (no manual "Build Now")
- [ ] Test → Build → Push to ECR all green
- [ ] image visible in ECR, tagged with the git SHA

*This is where the day can slip. Paste every error straight into Claude Code.*

---

## DAY 3 — Rolling deploy, verify, polish

### Phase 5 — Ansible rolling deploy · ⏱ 2–3 hrs
> Wire the Rolling deploy stage. Confirm the dynamic inventory finds both app
> instances by their Role=cicd-app tag. Run a deploy and watch Ansible update
> ONE host at a time, health-checking each before moving on.

- [ ] dynamic inventory lists both app hosts
- [ ] deploy updates host 1, health-checks, then host 2
- [ ] `http://<alb-dns>/` and `/health` return the new version
- [ ] Verify stage confirms the live SHA matches the build

**The money shot:** push a trivial code change, then curl the ALB in a loop
while the deploy runs — you should see zero failed requests as it rolls. Record
this; it's the strongest thing you can show an interviewer.

### Phase 6 — Docs, diagram, screenshots · ⏱ 1.5 hrs
> Write the README: architecture, how to run, and the three talking points.
> Generate an SVG architecture diagram matching the flow. 

- [ ] README done
- [ ] architecture.svg in docs/
- [ ] screenshots: pipeline green, ECR image, rolling deploy logs, ALB serving
- [ ] pushed to GitHub

---

## ⚠️ Teardown — everything is Terraform-managed

> Show me `terraform destroy` output and PAUSE before confirming. List anything
> that might survive destroy (e.g. ECR images) so I can clean those too.

- [ ] `terraform destroy` complete
- [ ] ECR images deleted if not needed
- [ ] `aws sts get-caller-identity` — confirm the right account before destroying

Running fleet costs money every hour: 2× t3.micro + 1× t3.small + ALB.

---

## Golden rules
- **Go phase by phase.** Never "build it all."
- **Review every `terraform apply` / `apply`-like command before approving.**
- **Paste errors straight into Claude Code** — the debug loop is its strength.
- **`claude doctor`** when something looks off.
- **`terraform validate` before every plan.**

## If a day slips
Priority order to preserve the portfolio value:
1. Rolling deploy working (Phase 5) — this is the differentiator
2. Webhook auto-trigger (Phase 4) — makes it read as *real* CI
3. Everything else is polish
If you must cut, cut polish — never the rolling deploy.
