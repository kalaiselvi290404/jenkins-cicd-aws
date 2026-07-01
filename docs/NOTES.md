# Engineering Notes

Key decisions made during the build and issues that came up and how they were fixed.

---

## Engineering decisions

### IAM instance roles, not access keys

Jenkins needs to push images to ECR. The tempting shortcut is to paste AWS
access keys into Jenkins credentials. Instead, the Jenkins EC2 carries an IAM
instance role (`AmazonEC2ContainerRegistryPowerUser` + a scoped inline policy).
The app instances carry a separate read-only role. The AWS CLI and Docker
credential helper on each instance pick up temporary credentials automatically
via the instance metadata service. No key is ever stored, rotated, or leaked.

The inline policy on the Jenkins role (`ec2:DescribeInstances`, `ec2:DescribeTags`)
is the minimum needed for Ansible's dynamic inventory plugin to discover the app
EC2 hosts at deploy time. It is separate from the ECR managed policy so the
scope of each permission is explicit.

### Ansible dynamic inventory over a static host list

The app instances are behind an ALB. Their IPs can change if instances are
replaced. A static Ansible inventory would break silently in that case. The
`amazon.aws.aws_ec2` plugin discovers hosts at deploy time by tag (`Role=cicd-app`,
state `running`) and uses their **private** IPs. This means the inventory always
reflects what's actually running, and new instances (or replacements) are picked
up automatically.

### Private IPs for intra-VPC SSH

The dynamic inventory plugin was initially configured to use `public_ip_address`
for `ansible_host`. SSH from the Jenkins instance to the app instances via their
public IPs failed with a timeout. The reason: AWS VPC does not support "hairpin
NAT" — a packet from inside the VPC destined for an instance's public Elastic IP
is dropped at the internet gateway rather than looped back internally. Switching
to `private_ip_address` fixed it immediately. All three instances are in the same
VPC and can reach each other via private IPs without leaving the network.

### Rolling deploy with serial: 1 and max_fail_percentage: 0

`serial: 1` means Ansible touches one host at a time. The ALB health checks
continuously, so as long as one instance is healthy, users see no downtime.
`max_fail_percentage: 0` means a single host failure halts the entire playbook —
the deploy does not roll forward if something is wrong. The old version keeps
serving on any untouched hosts. This is the safety net: a bad image can never
take down the whole fleet.

### Immutable ECR tags (git short SHA)

Every image is tagged with the git short SHA of the commit that built it.
ECR is configured with `image_tag_mutability = "IMMUTABLE"`. This means:

- You can always trace a running container back to its exact source commit.
- A tag cannot be overwritten by a later build (prevents silent rollbacks).
- The deploy playbook uses the same SHA that Jenkins built, so there is no
  ambiguity between what was tested and what was deployed.

### GitHub webhook: direct SG over tunnel relay

The webhook needs to reach Jenkins at port 8080. Two approaches were tried:

**smee.io relay (attempted first):** smee.io is a GitHub-maintained webhook
relay that forwards events via Server-Sent Events. The smee-client runs on
Jenkins and proxies incoming events to `localhost:8080/github-webhook/`. It
avoids opening the Jenkins SG to external IPs. However, the smee-client
(Node.js, v24) forwarded the original HTTP headers but Jenkins' GitHub plugin
(`RequirePostWithGHHookPayload` annotation in Stapler) rejected the relayed
requests with 405 — the Content-Type arrived as `null` at the plugin's payload
parser, and the method check failed even though the log showed `POST`. The
incompatibility was between how smee-client re-encodes SSE events as HTTP
requests and how Jenkins' Stapler framework reads the method from the servlet
request.

**Direct SG rule (used):** GitHub publishes its webhook source IP ranges at
`https://api.github.com/meta` (the `hooks` key). Adding these four IPv4 CIDRs
and two IPv6 CIDRs to the Jenkins security group on port 8080 allows GitHub to
POST directly to `http://<jenkins-ip>:8080/github-webhook/`. No relay process
to maintain, no compatibility risk, and the ranges are documented and stable.

---

## Issues encountered and fixed

### AWS SG descriptions rejected non-ASCII characters

Terraform's initial `security.tf` used em-dashes (—) in the security group
`description` fields. AWS `CreateSecurityGroup` API only accepts ASCII
characters in descriptions. Fixed by replacing em-dashes with hyphens.

### Jenkins 2023 signing key expired

The Jenkins apt repository key (`jenkins.io-2023.key`) expired on 2026-03-26.
`apt-get update` failed with a GPG signature error. Fixed by fetching the
current key (`jenkins.io-2026.key`) and re-importing it.

### Jenkins LTS 2026 requires Java 21

Jenkins LTS releases from early 2026 require a minimum of Java 21. The instance
had Java 17 installed. Fixed by installing OpenJDK 21, setting it as the default
with `update-alternatives`, and adding a systemd drop-in to set `JAVA_HOME`
explicitly so Jenkins starts on the correct JVM.

### python3-venv missing on Jenkins box

The `Test` stage creates a Python virtualenv to run pytest in isolation.
`python3 -m venv` failed because `python3-venv` was not installed on the Jenkins
EC2. Fixed with `sudo apt-get install -y python3.10-venv`.

### boto3/botocore not available to Ansible

The `amazon.aws.aws_ec2` dynamic inventory plugin is a Python library that
imports `boto3` and `botocore` at runtime. These were not installed on the
Jenkins system Python. Ansible uses the system Python (not the virtualenv created
for pytest), so the packages needed to be installed globally.
Fixed with `sudo pip3 install boto3 botocore`.

### ec2:DescribeInstances not authorized on Jenkins IAM role

The Jenkins IAM role was initially scoped to ECR operations only. When Ansible
ran the dynamic inventory plugin to discover app hosts, AWS returned
`AccessDenied` on `ec2:DescribeInstances`. Fixed by adding an inline IAM policy
(`aws_iam_role_policy.jenkins_ec2_describe` in `terraform/iam.tf`) granting
`ec2:DescribeInstances` and `ec2:DescribeTags` read-only across all resources.

### SSH from Jenkins to app instances timed out via public IPs

The Ansible inventory was configured to use `public_ip_address` for SSH.
SSH connections from Jenkins timed out even after the Jenkins security group was
added as an allowed source in the app security group. Root cause: intra-VPC
traffic destined for a public IP does not hairpin — it leaves the instance
toward the internet gateway, which drops it because the source is also inside
the VPC. Fixed by changing the inventory's `ansible_host` compose to
`private_ip_address`. The private IPs are reachable within the VPC without
leaving the network, and SSH connected immediately.
