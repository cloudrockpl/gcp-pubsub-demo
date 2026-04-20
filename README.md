# ☁️ GCP Pub/Sub Full Stack Architecture Demo

![GCP](https://img.shields.io/badge/Google_Cloud-4285F4?style=for-the-badge&logo=google-cloud&logoColor=white)
![React](https://img.shields.io/badge/React-20232A?style=for-the-badge&logo=react&logoColor=61DAFB)
![Python](https://img.shields.io/badge/Python-3776AB?style=for-the-badge&logo=python&logoColor=white)
![Bash](https://img.shields.io/badge/Bash-4EAA25?style=for-the-badge&logo=gnu-bash&logoColor=white)

An interactive, end-to-end training simulator designed to demonstrate the complete lifecycle of a message within Google Cloud Pub/Sub. 

This repository contains an automated Bash deployment script that provisions a fully functional architecture, including a React frontend, a Python (Flask) backend, and native GCP data sinks (BigQuery and Cloud Storage).

---

## 🏗 Architecture Overview

This project automatically provisions the following GCP resources:
1. **Frontend UI (Cloud Run):** A React SPA that acts as the publisher client and monitoring dashboard.
2. **Backend API (Cloud Run):** A Python Flask service that safely interacts with GCP APIs (Publishing, querying BQ, listing GCS blobs).
3. **Core Pub/Sub Topic:** The central fan-out message broker (`sensor-data`).
4. **Push Subscription:** Sends real-time Webhook POST requests to the Backend API.
5. **Pull Subscription:** Queues messages for manual acknowledgment demonstration.
6. **BigQuery Direct Sink:** Streams data directly from Pub/Sub into a BigQuery table.
7. **Cloud Storage Direct Sink:** Batches data directly from Pub/Sub into a GCS archive bucket.
8. **Dead Letter Topic (DLT):** Captures failed/NACKed messages after maximum delivery attempts.

<img width="2816" height="1536" alt="Gemini_Generated_v2" src="https://github.com/user-attachments/assets/09c5d369-bd27-4d82-99ca-fc28bfb0ba83" />


---

## 📋 Prerequisites

Before deploying, ensure you have the following installed and configured:

- A [Google Cloud Platform](https://cloud.google.com/) account with active billing.
- The [Google Cloud CLI (`gcloud`)](https://cloud.google.com/sdk/docs/install) installed locally.
- Authenticated with GCP:
  ```bash
  gcloud auth login
  gcloud auth application-default login
  
git clone https://github.com/cloudrockpl/gcp-pubsub-demo.git
cd gcp-pubsub-demo

chmod +x deploy_stack.sh cleanup-stack.sh

./deploy_stack.sh

Note: Deployment usually takes 5-8 minutes as it enables APIs, builds Docker containers via Cloud Build, deploys to Cloud Run, and provisions the Pub/Sub topics and Data Sinks.

🎓 Training Guide (How to Use)
Open the Frontend UI URL provided by the deployment script. The UI is numbered to match the logical flow of a message:

Data Ingestion: Fill out the Sensor ID and Temperature. Choose whether to send a single message or a batch. Toggle the "Simulate Backend Failure" switch to test error handling.

Core Topic: Watch messages hit the central fan-out broker.

Push Model: See real-time Webhook 200 OK (or simulated 500 Server Error) logs as messages are pushed.

Pull Model: Watch messages queue up. Click "Execute Pull & Send ACK" to process them.

Cloud Storage (Batch): Watch the buffer fill up. Once 5 messages are hit (or 1 minute passes), the subscription flushes a .json file into the GCS bucket.

BigQuery (Streaming): See data stream immediately into the BQ table via the UI polling.

Dead Letter Topic (DLT): If you simulated a backend failure or ignored pull messages, watch them drop into the DLT after 5 delivery attempts.

Cost Model Summary: Compare the billed kilobytes (kB) of sending individual messages versus batching them, demonstrating the 1kB minimum quota rule.

🧹 Clean Up
To avoid incurring ongoing charges for Cloud Run, Pub/Sub, and storage, run the cleanup script when you are finished with your training session:

Bash
./cleanup-stack.sh
This will automatically delete the Subscriptions, Topics, Cloud Run services, BigQuery datasets, Storage buckets, Artifact Registries, Service Accounts, and local generated code directories.
