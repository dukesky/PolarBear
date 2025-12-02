# Phase 6: Cloud Deployment Walkthrough

## Goal
Deploy the PolarBear application to Google Cloud Platform (GCP) using Cloud Run and set up a CI/CD pipeline with Cloud Build.

## Changes
1.  **Containerization**:
    -   Created `backend/Dockerfile` (Python 3.11, FastAPI).
    -   Created `frontend/Dockerfile` (Node 18, Next.js Standalone).
    -   Created `.dockerignore` to optimize build context.

2.  **CI/CD Pipeline**:
    -   Created `cloudbuild.yaml` to automate building and deploying both services to Cloud Run on every push to `main`.

3.  **Infrastructure**:
    -   Created `infrastructure/setup_gcp.sh` to enable APIs and create the Artifact Registry repo.
    -   Created `infrastructure/deploy_meilisearch_vm.sh` to deploy a persistent Meilisearch instance on GCE.

## Verification
-   **Docker Builds**: Verified that both backend and frontend Docker images build successfully locally.
    ```bash
    docker build -t polarbear-backend ./backend
    docker build -t polarbear-frontend ./frontend
    ```

## Deployment Instructions

### 1. Initial Setup
Run the setup script to enable APIs and create the repository:
```bash
./infrastructure/setup_gcp.sh <YOUR_PROJECT_ID>
```

### 2. Deploy Search Engine
Deploy the persistent Meilisearch instance:
```bash
./infrastructure/deploy_meilisearch_vm.sh
```
**Save the Output!** You will need the **External IP** and **Master Key**.

### 3. Connect CI/CD
1.  Go to [Cloud Build Triggers](https://console.cloud.google.com/cloud-build/triggers).
2.  Connect your GitHub repository.
3.  Create a trigger:
    -   **Event**: Push to a branch.
    -   **Source**: `^main$`
    -   **Configuration**: Cloud Build configuration file (`cloudbuild.yaml`).

### 4. Configure Environment Variables
After the first deployment (which might fail due to missing env vars), go to [Cloud Run Console](https://console.cloud.google.com/run):

**For Backend Service (`polarbear-backend`):**
-   `MEILI_HOST`: `http://<MEILISEARCH_VM_IP>:7700`
-   `MEILI_MASTER_KEY`: `<YOUR_MASTER_KEY>`

**For Frontend Service (`polarbear-frontend`):**
-   `NEXT_PUBLIC_API_URL`: The URL of your deployed Backend Service (e.g., `https://polarbear-backend-xyz-uc.a.run.app`).

### 5. Push to Deploy
Commit and push your changes to `main` to trigger the pipeline:
```bash
git add .
git commit -m "Deploy Phase 6"
git push origin main
```
