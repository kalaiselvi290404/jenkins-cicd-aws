# Small, production-ish image for the Flask app.
# Uses gunicorn (not the Flask dev server) so it's a realistic runtime.
FROM python:3.12-slim

# Don't buffer stdout/stderr — logs show up immediately in `docker logs`.
ENV PYTHONUNBUFFERED=1

WORKDIR /app

# Install deps first so this layer caches when only app code changes.
COPY app/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt gunicorn==22.0.0

# Copy the application code.
COPY app/ .

# APP_VERSION is overridden at build time by the pipeline (--build-arg).
ARG APP_VERSION=dev
ENV APP_VERSION=${APP_VERSION}

EXPOSE 5000

# 2 workers is plenty for a demo; bind to all interfaces on 5000.
CMD ["gunicorn", "--bind", "0.0.0.0:5000", "--workers", "2", "app:app"]
