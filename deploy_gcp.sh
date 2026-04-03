#!/usr/bin/env bash
# deploy_gcp.sh — package and deploy meshnarc subscriber to Cloud Run Jobs
set -euo pipefail

if [ -z "${1:-}" ]; then
  echo "Usage: $0 <gcp-project-id> [region] [job-name]"
  exit 1
fi

PROJECT="$1"
REGION="${2:-us-central1}"
JOB_NAME="${3:-meshnarc-sub}"

echo "Deploying $JOB_NAME to $REGION — hold onto your butts"

IMAGE="gcr.io/${PROJECT}/${JOB_NAME}:latest"

echo "--- Packaging and pushing image via Buildpacks ---"
gcloud builds submit --pack image="$IMAGE" --project "$PROJECT"

echo "--- Deploying Cloud Run Job ---"
# We override the command so the Buildpack's default web entrypoint is ignored
gcloud run jobs deploy "$JOB_NAME" \
    --image "$IMAGE" \
    --region "$REGION" \
    --project "$PROJECT" \
    --command "python" \
    --args "meshnarc_sub.py" \
    --max-retries 0 \
    --task-timeout 86400

echo ""
echo "NOTE: To set MQTT secrets and broker, run once:"
echo "gcloud run jobs update $JOB_NAME --region $REGION --update-env-vars MESHNARC_BROKER=your-broker,MESHNARC_MQTT_USER=user,MESHNARC_MQTT_PASS=pass"
echo ""

echo "--- Starting Job Execution ---"
gcloud run jobs execute "$JOB_NAME" --region "$REGION" --project "$PROJECT" --wait=false

echo "=== deploy complete ==="
