# Implementation Plan - Phase 6: Cloud Deployment

## Goal Description
Deploy the PolarBear application to Google Cloud Platform (GCP) and set up a CI/CD pipeline so that every push to `main` triggers a new deployment.

## User Review Required
> [!IMPORTANT]
> **Meilisearch Persistence**:
> Cloud Run is stateless. To persist search data, we will deploy Meilisearch to a small **Compute Engine (VM)** instance.
> -   **Cost**: ~$5-10/month for an e2-micro/small instance.
> -   **Security**: We will secure it with a Master Key.

> [!NOTE]
> **Prerequisites**:
> You must have the `gcloud` CLI installed and authenticated with your GCP project.

## Proposed Changes

### 1. Containerization
#### [NEW] `backend/Dockerfile`
-   Python 3.11-slim base.
-   Install Poetry.
-   Install dependencies.
-   Copy code.
-   CMD: `uvicorn app.main:app --host 0.0.0.0 --port $PORT`

#### [NEW] `frontend/Dockerfile`
-   Node 18-alpine base.
-   Multi-stage build (deps -> builder -> runner).
-   Next.js standalone output.
-   CMD: `node server.js`

### 2. CI/CD Pipeline
#### [NEW] `cloudbuild.yaml`
-   **Step 1**: Build Backend Image.
-   **Step 2**: Build Frontend Image.
-   **Step 3**: Push Images to Artifact Registry (or GCR).
-   **Step 4**: Deploy Backend to Cloud Run.
-   **Step 5**: Deploy Frontend to Cloud Run.

### 3. Infrastructure Scripts
#### [NEW] `infrastructure/deploy_meilisearch_vm.sh`
-   Script to create a GCE VM running Meilisearch Docker container.
-   Sets up a static IP and firewall rule (port 7700).
-   Outputs the IP and Master Key.

#### [NEW] `infrastructure/setup_gcp.sh`
-   Enables required APIs (Cloud Run, Cloud Build, Artifact Registry, Compute Engine).
-   Creates Artifact Registry repository.

## Verification Plan

### Automated
-   `docker build` locally to verify Dockerfiles work.

### Manual Verification (User)
1.  Run `setup_gcp.sh`.
2.  Run `deploy_meilisearch_vm.sh` to get the Search URL and Key.
3.  Connect GitHub repo to Cloud Build (User action).
4.  Push changes to `main`.
5.  Verify Cloud Build triggers and deploys successfully.
6.  Access the public Cloud Run URLs.
