"""
Project 2 — Flask CI/CD demo app.

Two routes:
  /        -> a simple hello response with the build/version info
  /health  -> a health check the load balancer and deploy step poll

The version string is read from an env var (APP_VERSION) that the Jenkins
pipeline injects at build time (the git short SHA). This lets you prove, from
the browser, exactly which build is live on each instance during a rolling
deploy — a great thing to show in an interview.
"""
import os
from flask import Flask, jsonify

app = Flask(__name__)

APP_VERSION = os.environ.get("APP_VERSION", "dev")


@app.route("/")
def index():
    return jsonify(
        message="Hello from Kalaiselvi's CI/CD pipeline",
        version=APP_VERSION,
    )


@app.route("/health")
def health():
    # Kept intentionally cheap and dependency-free so the load balancer and the
    # Ansible rolling deploy can poll it frequently without side effects.
    return jsonify(status="healthy", version=APP_VERSION), 200


if __name__ == "__main__":
    # 0.0.0.0 so the container is reachable from outside; port 5000 by convention.
    app.run(host="0.0.0.0", port=5000)
