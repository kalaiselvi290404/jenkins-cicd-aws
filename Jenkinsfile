// Project 2 — full-scope declarative pipeline.
//
// Trigger: GitHub webhook (configured in the Jenkins job as "GitHub hook
// trigger for GITScm polling"). Every push to the repo fires this pipeline.
//
// Flow: Checkout -> Test -> Build image -> Push to ECR -> Rolling deploy via
// Ansible across 2+ EC2 instances behind an ALB -> Verify health.
//
// Credentials/permissions: the Jenkins EC2 box has an IAM *instance role*
// granting ECR push. No long-lived AWS keys live in Jenkins. That's the
// second interview talking point, made real.

pipeline {
    agent any

    environment {
        // ---- EDIT THESE for the environment ----
        AWS_REGION   = 'ap-south-1'                 // Mumbai; matches Chennai user
        ECR_REGISTRY = ''                           // e.g. 123456789012.dkr.ecr.ap-south-1.amazonaws.com
        ECR_REPO     = 'kalaiselvi-cicd-app'
        ALB_DNS      = ''                           // from `terraform output alb_dns_name`
        // ----------------------------------------

        // Short git SHA — used as the immutable image tag and the live version.
        IMAGE_TAG = "${env.GIT_COMMIT?.take(7) ?: 'manual'}"
        IMAGE_URI = "${ECR_REGISTRY}/${ECR_REPO}:${IMAGE_TAG}"
    }

    options {
        timestamps()
        disableConcurrentBuilds()        // never two deploys racing each other
        buildDiscarder(logRotator(numToKeepStr: '20'))
    }

    stages {

        stage('Checkout') {
            steps {
                checkout scm
                sh 'echo "Building commit: ${GIT_COMMIT}"'
            }
        }

        stage('Test') {
            // If this fails, the pipeline stops here and NO image is built,
            // so broken code can never reach the EC2 hosts.
            steps {
                sh '''
                    python3 -m venv .venv
                    . .venv/bin/activate
                    pip install -r app/requirements.txt
                    cd app && python -m pytest -v
                '''
            }
        }

        stage('Build image') {
            steps {
                sh '''
                    docker build \
                      --build-arg APP_VERSION=${IMAGE_TAG} \
                      -t ${IMAGE_URI} .
                '''
            }
        }

        stage('Push to ECR') {
            steps {
                // get-login-password uses the instance role — no stored keys.
                sh '''
                    aws ecr get-login-password --region ${AWS_REGION} \
                      | docker login --username AWS --password-stdin ${ECR_REGISTRY}
                    docker push ${IMAGE_URI}
                '''
            }
        }

        stage('Rolling deploy') {
            // Ansible updates the app hosts ONE AT A TIME (serial: 1). Each host
            // is pulled from rotation, updated, health-checked, and only then
            // does Ansible move to the next. Zero downtime.
            steps {
                sh '''
                    ansible-playbook \
                      -i ansible/inventory.aws_ec2.yml \
                      ansible/deploy.yml \
                      -e "image_uri=${IMAGE_URI}" \
                      -e "aws_region=${AWS_REGION}" \
                      -e "ecr_registry=${ECR_REGISTRY}"
                '''
            }
        }

        stage('Verify') {
            // Hit the ALB and confirm the live version matches what we just shipped.
            steps {
                sh '''
                    echo "Verifying deploy of ${IMAGE_TAG} via the load balancer..."
                    for i in $(seq 1 10); do
                      LIVE=$(curl -s http://${ALB_DNS}/health | grep -o '"version":"[^"]*"' || true)
                      echo "attempt $i: ${LIVE}"
                      echo "${LIVE}" | grep "${IMAGE_TAG}" && { echo "Deploy verified."; exit 0; }
                      sleep 6
                    done
                    echo "Could not confirm new version live in time." >&2
                    exit 1
                '''
            }
        }
    }

    post {
        success { echo "Pipeline succeeded — ${IMAGE_TAG} is live." }
        failure { echo "Pipeline failed — previous version remains live (rollback is automatic since we never touched the old image)." }
        always  { sh 'docker image prune -f || true' }
    }
}
