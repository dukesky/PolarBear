#!/bin/bash

# Check if project ID is provided
if [ -z "$1" ]; then
    echo "Usage: ./setup_gcp.sh <PROJECT_ID>"
    exit 1
fi

PROJECT_ID=$1
REGION="us-central1"
REPO_NAME="polarbear-repo"

echo "🚀 Setting up GCP Project: $PROJECT_ID"

# Set project
gcloud config set project $PROJECT_ID

# Enable APIs
echo "🔌 Enabling required APIs..."
gcloud services enable \
    cloudbuild.googleapis.com \
    run.googleapis.com \
    artifactregistry.googleapis.com \
    compute.googleapis.com

# Create Artifact Registry Repository
echo "📦 Creating Artifact Registry Repository..."
gcloud artifacts repositories create $REPO_NAME \
    --repository-format=docker \
    --location=$REGION \
    --description="Docker repository for PolarBear"

echo "✅ Setup Complete!"
echo "You can now connect your GitHub repository to Cloud Build."
