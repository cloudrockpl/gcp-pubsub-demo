#!/bin/bash
# ==============================================================================
# GCP Clean Up Script
# Run this after your presentation to remove all provisioned resources
# and local generated source code.
# ==============================================================================

PROJECT_ID=$(gcloud config get-value project)
REGION="us-central1"
REPO_NAME="pubsub-demo-repo"
SA_NAME="pubsub-demo-sa"

# Match these to your deployment script
TOPIC_ID="sensor-data"
DLT_ID="sensor-data-dlt"
PULL_SUB="dwh-pull"
PUSH_SUB="rt-push"
BQ_SUB="bq-streaming-sub"
GCS_SUB="gcs-archive-sub"
BQ_DATASET="sensor_analytics"

echo "=========================================================="
echo " TEARING DOWN ARCHITECTURE IN: $PROJECT_ID"
echo "=========================================================="

# 1. Delete Subscriptions
echo "[1/8] Deleting Pub/Sub Subscriptions..."
gcloud pubsub subscriptions delete $PULL_SUB $PUSH_SUB $BQ_SUB $GCS_SUB --quiet || true

# 2. Delete Topics
echo "[2/8] Deleting Pub/Sub Topics..."
gcloud pubsub topics delete $TOPIC_ID $DLT_ID --quiet || true

# 3. Delete Cloud Run Services
echo "[3/8] Deleting Cloud Run Services..."
gcloud run services delete frontend-service --region=$REGION --quiet || true
gcloud run services delete backend-service --region=$REGION --quiet || true

# 4. Delete BigQuery Dataset
echo "[4/8] Deleting BigQuery Dataset & Tables..."
bq rm -r -f -d ${PROJECT_ID}:${BQ_DATASET} || true

# 5. Delete Cloud Storage Bucket
# Note: Searching for the bucket prefix since we appended a random suffix
echo "[5/8] Deleting Cloud Storage Archive Buckets..."
BUCKET_LIST=$(gcloud storage ls | grep "${PROJECT_ID}-pubsub-archive-" || true)
if [ ! -z "$BUCKET_LIST" ]; then
    gcloud storage rm -r $BUCKET_LIST --quiet || true
fi

# 6. Delete Artifact Registry
echo "[6/8] Deleting Artifact Registry Repo..."
gcloud artifacts repositories delete $REPO_NAME --location=$REGION --quiet || true

# 7. Delete Service Account
echo "[7/8] Deleting Service Account..."
SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
gcloud iam service-accounts delete $SA_EMAIL --quiet || true

# 8. Clean up local generated source code
echo "[8/8] Deleting local generated source code..."
rm -rf frontend backend
echo "Removed local 'frontend' and 'backend' directories."

echo "=========================================================="
echo " CLEAN UP COMPLETE "
echo "=========================================================="
