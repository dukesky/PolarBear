#!/bin/bash

# Set variables
INSTANCE_NAME="polarbear-meilisearch"
ZONE="us-central1-a"
MACHINE_TYPE="e2-small"
MEILI_MASTER_KEY=$(openssl rand -base64 32)

echo "🚀 Deploying Meilisearch on Google Compute Engine..."
echo "🔑 Generated Master Key: $MEILI_MASTER_KEY"

# Create VM with Docker and Meilisearch container
gcloud compute instances create-with-container $INSTANCE_NAME \
    --zone=$ZONE \
    --machine-type=$MACHINE_TYPE \
    --container-image="getmeili/meilisearch:v1.12" \
    --container-env="MEILI_MASTER_KEY=$MEILI_MASTER_KEY" \
    --tags=meilisearch-server

# Create firewall rule to allow traffic on port 7700
echo "🛡️ Creating firewall rule..."
gcloud compute firewall-rules create allow-meilisearch \
    --allow tcp:7700 \
    --target-tags=meilisearch-server \
    --description="Allow Meilisearch traffic"

# Get External IP
EXTERNAL_IP=$(gcloud compute instances describe $INSTANCE_NAME --zone=$ZONE --format='get(networkInterfaces[0].accessConfigs[0].natIP)')

echo "✅ Deployment Complete!"
echo "--------------------------------------------------"
echo "🌍 Meilisearch URL: http://$EXTERNAL_IP:7700"
echo "🔑 Master Key: $MEILI_MASTER_KEY"
echo "--------------------------------------------------"
echo "⚠️  IMPORTANT: Update your Cloud Run Backend Environment Variables with these values:"
echo "   MEILI_HOST='http://$EXTERNAL_IP:7700'"
echo "   MEILI_MASTER_KEY='$MEILI_MASTER_KEY'"
