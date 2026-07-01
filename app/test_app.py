"""
Unit tests for the Flask app.

The pipeline runs these BEFORE building the Docker image. If any test fails,
the image is never built and nothing reaches the EC2 hosts — this is the
"broken code can't reach production" talking point, made real.
"""
import app as flask_app_module


def _client():
    flask_app_module.app.config.update(TESTING=True)
    return flask_app_module.app.test_client()


def test_index_returns_200_and_message():
    res = _client().get("/")
    assert res.status_code == 200
    data = res.get_json()
    assert "message" in data
    assert "version" in data


def test_health_returns_healthy():
    res = _client().get("/health")
    assert res.status_code == 200
    data = res.get_json()
    assert data["status"] == "healthy"
