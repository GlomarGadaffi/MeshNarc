param(
    [Parameter(Mandatory=$true)][string]$Project,
    [string]$Region = "us-central1",
    [string]$JobName = "meshnarc-sub"
)

$ErrorActionPreference = "Stop"

Write-Host "Deploying $JobName to $Region — hold onto your butts"

# Using Buildpacks to build the container image
$Image = "gcr.io/$Project/$JobName:latest"

Write-Host "--- Packaging and pushing image via Buildpacks ---"
gcloud builds submit --pack image=$Image --project $Project

Write-Host "--- Deploying Cloud Run Job ---"
# We override the command so the Buildpack's default web entrypoint is ignored
gcloud run jobs deploy $JobName `
    --image $Image `
    --region $Region `
    --project $Project `
    --command "python" `
    --args "meshnarc_sub.py" `
    --max-retries 0 `
    --task-timeout 86400

Write-Host ""
Write-Host "NOTE: To set MQTT secrets and broker, run once:"
Write-Host "gcloud run jobs update $JobName --region $Region --update-env-vars MESHNARC_BROKER=your-broker,MESHNARC_MQTT_USER=user,MESHNARC_MQTT_PASS=pass"
Write-Host ""

Write-Host "--- Starting Job Execution ---"
# Cloud Run Jobs can be executed repeatedly. Wait=$false drops us back to the prompt.
gcloud run jobs execute $JobName --region $Region --project $Project --wait=$false

Write-Host "=== deploy complete ==="
