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
  
