# syntax=docker/dockerfile:1

FROM python:3.12-slim

# Non-root: Kyverno policy in this repo rejects root containers, so the image
# has to be built correctly or the demo fails at the policy gate (by design).
RUN useradd --uid 10001 --create-home --shell /usr/sbin/nologin app

WORKDIR /app
COPY app/main.py /app/main.py

USER 10001
EXPOSE 8080

ARG APP_VERSION=dev
ENV APP_VERSION=${APP_VERSION}

HEALTHCHECK --interval=30s --timeout=3s \
  CMD python -c "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8080/healthz').status==200 else 1)"

ENTRYPOINT ["python", "/app/main.py"]
