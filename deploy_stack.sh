#!/bin/bash
# ==============================================================================
# GCP Pub/Sub Full Stack Architecture - Deployment Script (v1)
# Provisions GCP Infrastructure, Python Flask Backend, and React Frontend.
# ==============================================================================

set -e # Exit immediately on error

# --- CONFIGURATION ---
PROJECT_ID=$(gcloud config get-value project)
REGION="us-central1"
REPO_NAME="pubsub-demo-repo"

SA_NAME="pubsub-demo-sa"
SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

# Infrastructure Names
TOPIC_ID="sensor-data"
DLT_ID="sensor-data-dlt"
PULL_SUB="dwh-pull"
PUSH_SUB="rt-push"
BQ_SUB="bq-streaming-sub"
GCS_SUB="gcs-archive-sub"

BQ_DATASET="sensor_analytics"
BQ_TABLE="realtime_data"
GCS_BUCKET="${PROJECT_ID}-pubsub-archive-$RANDOM" 

FRONTEND_IMAGE="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPO_NAME}/frontend:latest"
BACKEND_IMAGE="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPO_NAME}/backend:latest"

echo "=========================================================="
echo " Deploying Full Stack Architecture for: $PROJECT_ID"
echo "=========================================================="

echo -e "\n[1/10] Enabling Required GCP APIs..."
gcloud services enable run.googleapis.com pubsub.googleapis.com \
    artifactregistry.googleapis.com cloudbuild.googleapis.com \
    bigquery.googleapis.com storage.googleapis.com

echo "Waiting 10 seconds for APIs to propagate..."
sleep 10

echo -e "\n[2/10] Creating Service Account & Assigning IAM Roles..."
PROJECT_NUMBER=$(gcloud projects describe $PROJECT_ID --format="value(projectNumber)")
gcloud iam service-accounts create $SA_NAME --display-name="PubSub Demo SA" || true

# Grant required roles
for ROLE in "roles/run.invoker" "roles/pubsub.editor" "roles/bigquery.dataEditor" "roles/storage.objectAdmin" "roles/artifactregistry.writer" "roles/bigquery.jobUser"; do
    gcloud projects add-iam-policy-binding $PROJECT_ID \
        --member="serviceAccount:${SA_EMAIL}" \
        --role="$ROLE" > /dev/null
done

# Cloud Build SA Permissions
gcloud projects add-iam-policy-binding $PROJECT_ID --member="serviceAccount:${PROJECT_NUMBER}@cloudbuild.gserviceaccount.com" --role="roles/artifactregistry.writer" > /dev/null || true
gcloud projects add-iam-policy-binding $PROJECT_ID --member="serviceAccount:${PROJECT_NUMBER}-compute@developer.gserviceaccount.com" --role="roles/artifactregistry.writer" > /dev/null || true

echo -e "\n[3/10] Setting up Artifact Registry..."
gcloud artifacts repositories create $REPO_NAME --repository-format=docker --location=$REGION || echo "Repo exists."

echo -e "\n[4/10] Provisioning Cloud Infrastructure (Topics, BQ, GCS)..."
gcloud pubsub topics create $DLT_ID || true
gcloud pubsub topics create $TOPIC_ID || true

bq mk --location=$REGION -d $BQ_DATASET || true
# BQ Tool requires colon (:) between project and dataset
bq mk --table ${PROJECT_ID}:${BQ_DATASET}.${BQ_TABLE} subscription_name:STRING,message_id:STRING,publish_time:TIMESTAMP,data:STRING,attributes:STRING || true

gcloud storage buckets create gs://$GCS_BUCKET --location=$REGION || true

echo -e "\n[5/10] Generating Backend Source Code (Flask)..."
mkdir -p backend

cat << 'EOF' > backend/app.py
import os
import json
import base64
from flask import Flask, request, jsonify
from flask_cors import CORS
from google.cloud import pubsub_v1
from google.cloud import bigquery
from google.cloud import storage

app = Flask(__name__)
CORS(app)

PROJECT_ID = os.environ.get('PROJECT_ID')
TOPIC_ID = os.environ.get('TOPIC_ID')
BQ_DATASET = os.environ.get('BQ_DATASET')
BQ_TABLE = os.environ.get('BQ_TABLE')
GCS_BUCKET = os.environ.get('GCS_BUCKET')

# Enable message ordering on the publisher
pub_options = pubsub_v1.types.PublisherOptions(enable_message_ordering=True)
pub_client = pubsub_v1.PublisherClient(publisher_options=pub_options)
bq_client = bigquery.Client(project=PROJECT_ID)
storage_client = storage.Client(project=PROJECT_ID)

@app.route('/api/publish', methods=['POST'])
def publish_message():
    req = request.get_json()
    messages = req.get('messages', [])
    topic_path = pub_client.topic_path(PROJECT_ID, TOPIC_ID)
    
    published_ids = []
    for msg in messages:
        order_key = msg.get('orderKey', '')
        payload = msg.get('payload', {})
        if msg.get('fail'):
            payload['fail'] = True
            
        data = json.dumps(payload).encode('utf-8')
        
        if order_key:
            future = pub_client.publish(topic_path, data, ordering_key=order_key)
        else:
            future = pub_client.publish(topic_path, data)
            
        published_ids.append(future.result())
        
    return jsonify({"published_ids": published_ids, "status": "success"}), 200

@app.route('/api/bq', methods=['GET'])
def get_bq_data():
    query = f"SELECT message_id, publish_time, data FROM `{PROJECT_ID}.{BQ_DATASET}.{BQ_TABLE}` ORDER BY publish_time DESC LIMIT 5"
    try:
        query_job = bq_client.query(query)
        results = []
        for row in query_job:
            results.append({
                "id": row["message_id"],
                "time": row["publish_time"].isoformat() if row["publish_time"] else None,
                "data": row["data"]
            })
        return jsonify(results), 200
    except Exception as e:
        return jsonify({"error": str(e)}), 500

@app.route('/api/gcs', methods=['GET'])
def get_gcs_data():
    try:
        bucket = storage_client.bucket(GCS_BUCKET)
        blobs = bucket.list_blobs()
        files = []
        for b in blobs:
            files.append({
                "filename": b.name,
                "size": b.size,
                "time": b.time_created.isoformat() if b.time_created else None
            })
        files.sort(key=lambda x: x['time'] or '', reverse=True)
        return jsonify(files[:5]), 200
    except Exception as e:
        return jsonify({"error": str(e)}), 500

@app.route('/api/messages', methods=['POST'])
def handle_pubsub_push():
    envelope = request.get_json()
    if not envelope:
        return 'Bad Request', 400
    
    pubsub_message = envelope.get('message', {})
    data_b64 = pubsub_message.get('data', '')
    
    try:
        data_str = base64.b64decode(data_b64).decode('utf-8')
        payload = json.loads(data_str)
        if payload.get('fail') is True:
            return 'Simulated 500 Error', 500
    except:
        pass
        
    return ('', 204)

if __name__ == '__main__':
    port = int(os.environ.get('PORT', 8080))
    app.run(debug=True, host='0.0.0.0', port=port)
EOF

cat << 'EOF' > backend/requirements.txt
Flask==3.0.0
gunicorn==21.2.0
flask-cors==4.0.0
google-cloud-pubsub==2.19.0
google-cloud-bigquery==3.14.1
google-cloud-storage==2.14.0
EOF

cat << 'EOF' > backend/Dockerfile
FROM python:3.11-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
CMD ["gunicorn", "--bind", "0.0.0.0:8080", "app:app"]
EOF

echo -e "\n[6/10] Building & Deploying Backend via Cloud Build..."
gcloud builds submit ./backend --tag $BACKEND_IMAGE

BACKEND_URL=$(gcloud run deploy backend-service \
    --image=$BACKEND_IMAGE \
    --region=$REGION --service-account=$SA_EMAIL \
    --allow-unauthenticated \
    --set-env-vars PROJECT_ID=$PROJECT_ID,TOPIC_ID=$TOPIC_ID,BQ_DATASET=$BQ_DATASET,BQ_TABLE=$BQ_TABLE,GCS_BUCKET=$GCS_BUCKET \
    --format='value(status.url)')

echo -e "\n[7/10] Creating Pub/Sub Subscriptions..."
# Enable message ordering on Push/Pull subscriptions
gcloud pubsub subscriptions create $PULL_SUB --topic=$TOPIC_ID --dead-letter-topic=$DLT_ID --max-delivery-attempts=5 --enable-message-ordering || true
gcloud pubsub subscriptions create $PUSH_SUB --topic=$TOPIC_ID --push-endpoint="${BACKEND_URL}/api/messages" --push-auth-service-account=$SA_EMAIL --enable-message-ordering || true

PUBSUB_AGENT="serviceAccount:service-${PROJECT_NUMBER}@gcp-sa-pubsub.iam.gserviceaccount.com"

echo "Granting BigQuery roles to Pub/Sub agent..."
gcloud projects add-iam-policy-binding $PROJECT_ID --member="$PUBSUB_AGENT" --role="roles/bigquery.dataEditor" > /dev/null
gcloud projects add-iam-policy-binding $PROJECT_ID --member="$PUBSUB_AGENT" --role="roles/bigquery.metadataViewer" > /dev/null

echo "Creating BigQuery Direct Subscription..."
# FIX: gcloud pubsub requires dot (.) notation between PROJECT_ID and BQ_DATASET
gcloud pubsub subscriptions create $BQ_SUB \
    --topic=$TOPIC_ID \
    --bigquery-table="${PROJECT_ID}.${BQ_DATASET}.${BQ_TABLE}" \
    --write-metadata

echo "Granting Cloud Storage roles to Pub/Sub agent..."
gcloud projects add-iam-policy-binding $PROJECT_ID --member="$PUBSUB_AGENT" --role="roles/storage.admin" > /dev/null

echo "Creating Cloud Storage Direct Subscription..."
# FIX: changed --cloud-storage-file-format to the correct flag --cloud-storage-output-format
gcloud pubsub subscriptions create $GCS_SUB \
    --topic=$TOPIC_ID \
    --cloud-storage-bucket=$GCS_BUCKET \
    --cloud-storage-output-format=text \
    --cloud-storage-max-duration=1m \
    --cloud-storage-max-bytes=1000

echo -e "\n[8/10] Generating Frontend Source Code (React + Vite)..."
mkdir -p frontend/src

# Create config to safely inject backend URL
cat << 'EOF' > frontend/src/config.js
export const API_URL = "REPLACE_ME_API_URL";
EOF
sed -i "s|REPLACE_ME_API_URL|${BACKEND_URL}|g" frontend/src/config.js

cat << 'EOF' > frontend/package.json
{
  "name": "pubsub-simulator",
  "version": "1.0.0",
  "type": "module",
  "scripts": { "dev": "vite", "build": "vite build" },
  "dependencies": { "lucide-react": "^0.292.0", "react": "^18.2.0", "react-dom": "^18.2.0" },
  "devDependencies": { "@vitejs/plugin-react": "^4.2.0", "autoprefixer": "^10.4.16", "postcss": "^8.4.31", "tailwindcss": "^3.3.5", "vite": "^5.0.0" }
}
EOF

cat << 'EOF' > frontend/vite.config.js
import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
export default defineConfig({ plugins: [react()] })
EOF

cat << 'EOF' > frontend/tailwind.config.js
export default { content: ["./index.html", "./src/**/*.{js,ts,jsx,tsx}"], theme: { extend: {} }, plugins: [] }
EOF

cat << 'EOF' > frontend/postcss.config.js
export default { plugins: { tailwindcss: {}, autoprefixer: {} } }
EOF

cat << 'EOF' > frontend/index.html
<!doctype html>
<html lang="en">
  <head><meta charset="UTF-8" /><meta name="viewport" content="width=device-width, initial-scale=1.0" /><title>Pub/Sub App</title></head>
  <body><div id="root"></div><script type="module" src="/src/main.jsx"></script></body>
</html>
EOF

cat << 'EOF' > frontend/src/index.css
@tailwind base; @tailwind components; @tailwind utilities;
EOF

cat << 'EOF' > frontend/src/main.jsx
import React from 'react'; import ReactDOM from 'react-dom/client'; import App from './App.jsx'; import './index.css';
ReactDOM.createRoot(document.getElementById('root')).render(<React.StrictMode><App /></React.StrictMode>);
EOF

# Injecting the App.jsx with added UI error logging for APIs
cat << 'EOF' > frontend/src/App.jsx
import React, { useState, useEffect } from 'react';
import { 
  Server, Database, AlertTriangle, CheckCircle, RefreshCw, 
  DollarSign, Send, Activity, Table, HardDrive, FileText, 
  Shield, ArrowDown, Share2
} from 'lucide-react';
import { API_URL } from './config.js';

export default function App() {
  const [sensorId, setSensorId] = useState('SENS-1024');
  const [temperature, setTemperature] = useState('45.2');
  const [orderKey, setOrderKey] = useState('region-eu');
  const [forceFail, setForceFail] = useState(false);
  const [batchCount, setBatchCount] = useState(1);

  const [topicLog, setTopicLog] = useState([]);
  const [pushLog, setPushLog] = useState([]);
  const [pullQueue, setPullQueue] = useState([]);
  const [dltLog, setDltLog] = useState([]);
  const [gcsFiles, setGcsFiles] = useState([]);
  const [bqLog, setBqLog] = useState([]);
  
  const [billingKb, setBillingKb] = useState(0);
  const [messageCount, setMessageCount] = useState(0);

  const generateId = () => Math.random().toString(36).substring(2, 9);
  const calcSize = (text) => { try { return text ? text.length : 0; } catch (e) { return 0; } };

  // --- ACTUAL BACKEND POLLING ---
  useEffect(() => {
    const bqInterval = setInterval(() => {
      fetch(API_URL + '/api/bq').then(r => r.json()).then(data => {
        if(Array.isArray(data)) {
          const parsed = data.map(row => {
            let parsedData = {};
            try { parsedData = JSON.parse(row.data); } catch(e) {}
            return { time: row.time ? new Date(row.time).toLocaleTimeString() : 'N/A', payload: parsedData };
          });
          setBqLog(parsed);
        } else if (data.error) {
          console.error("BQ Polling Error:", data.error);
        }
      }).catch(e => console.log('BQ Poll Fetch Error:', e));
    }, 3000);

    const gcsInterval = setInterval(() => {
      fetch(API_URL + '/api/gcs').then(r => r.json()).then(data => {
        if(Array.isArray(data)) {
          setGcsFiles(data.map(f => ({ ...f, time: new Date(f.time).toLocaleTimeString() })));
        } else if (data.error) {
          console.error("GCS Polling Error:", data.error);
        }
      }).catch(e => console.log('GCS Poll Fetch Error:', e));
    }, 5000);

    return () => { clearInterval(bqInterval); clearInterval(gcsInterval); };
  }, []);

  // --- PUBLISH LOGIC ---
  const publishMessage = async () => {
    const payloadObj = { sensor_id: sensorId, temp: parseFloat(temperature) || 0 };
    const payloadStr = JSON.stringify(payloadObj);
    const size = calcSize(payloadStr);
    
    let billedSize = batchCount > 1 ? Math.max(1, Math.ceil((size * batchCount) / 1000)) : Math.max(1, Math.ceil(size / 1000));
    setBillingKb(prev => prev + billedSize);
    setMessageCount(prev => prev + batchCount);

    const newMsgs = [];
    for(let i = 0; i < batchCount; i++) {
      newMsgs.push({
        id: generateId(),
        payload: payloadObj,
        raw: payloadStr,
        orderKey: orderKey,
        fail: forceFail,
        timestamp: new Date().toLocaleTimeString()
      });
    }

    setTopicLog(prev => [...newMsgs, ...prev].slice(0, 5));

    // Send Real API Request
    try {
        await fetch(API_URL + '/api/publish', {
            method: 'POST',
            headers: {'Content-Type': 'application/json'},
            body: JSON.stringify({messages: newMsgs})
        });
    } catch(e) {
        console.error("Publish API failed, running in visual sim mode.", e);
    }

    // Simulate internal visuals
    setTimeout(() => {
      const unacked = newMsgs.map(m => ({ ...m, status: 'unacked' }));
      unacked.forEach((msg, idx) => {
        setTimeout(() => {
          if (msg.fail) setDltLog(prev => [{ ...msg, reason: 'Push 500 Error' }, ...prev].slice(0, 5));
          else setPushLog(prev => [{ ...msg, status: 'acked' }, ...prev].slice(0, 5));
        }, 300 + (idx * 150));
      });
      setPullQueue(prev => [...unacked, ...prev]);
    }, 600);
  };

  const handlePullDelivery = () => {
    if (pullQueue.length === 0) return;
    const processing = pullQueue.slice(0, 5); 
    processing.forEach(msg => {
      if (msg.fail) setDltLog(prev => [{ ...msg, reason: 'Pull Ack Timeout' }, ...prev].slice(0, 5));
    });
    setPullQueue(pullQueue.slice(5));
  };

  return (
    <div className="min-h-screen bg-slate-950 text-slate-200 p-6 font-sans">
      <header className="mb-8 text-center border-b border-slate-800 pb-6">
        <h1 className="text-3xl font-extrabold text-transparent bg-clip-text bg-gradient-to-r from-blue-400 to-teal-400">GCP Pub/Sub: Message Lifecycle Training</h1>
        <p className="text-slate-400 mt-2">Follow the exact path of a message from ingestion to analytics.</p>
      </header>

      <div className="max-w-6xl mx-auto space-y-8">
        {/* STEP 1 */}
        <section className="bg-slate-900 border border-slate-800 rounded-xl p-6 shadow-lg relative">
          <div className="absolute -top-3 -left-3 bg-blue-600 text-white w-8 h-8 flex items-center justify-center rounded-full font-bold shadow">1</div>
          <h2 className="text-xl font-bold text-blue-300 flex items-center gap-2 mb-4"><Server className="w-5 h-5"/> Data Ingestion (Publisher)</h2>
          <div className="grid grid-cols-1 md:grid-cols-4 gap-4 mb-4">
            <div><label className="block text-xs text-slate-400 mb-1">Sensor ID</label><input value={sensorId} onChange={e => setSensorId(e.target.value)} className="w-full bg-slate-950 border border-slate-700 rounded p-2 text-sm text-green-400 font-mono" /></div>
            <div><label className="block text-xs text-slate-400 mb-1">Temperature</label><input value={temperature} onChange={e => setTemperature(e.target.value)} type="number" className="w-full bg-slate-950 border border-slate-700 rounded p-2 text-sm text-green-400 font-mono" /></div>
            <div><label className="block text-xs text-slate-400 mb-1">Ordering Key</label><input value={orderKey} onChange={e => setOrderKey(e.target.value)} className="w-full bg-slate-950 border border-slate-700 rounded p-2 text-sm text-purple-400 font-mono" /></div>
            <div><label className="block text-xs text-slate-400 mb-1">Batch Settings</label><select value={batchCount} onChange={e => setBatchCount(Number(e.target.value))} className="w-full bg-slate-950 border border-slate-700 rounded p-2 text-sm text-slate-300"><option value={1}>Single Message</option><option value={5}>Batch of 5</option><option value={10}>Batch of 10</option></select></div>
          </div>
          <div className="flex items-center justify-between bg-slate-950 p-4 rounded-lg border border-slate-800">
            <div className="flex items-center gap-3"><input type="checkbox" id="forceFail" checked={forceFail} onChange={e => setForceFail(e.target.checked)} className="w-5 h-5 rounded border-slate-600 text-red-500 bg-slate-900 cursor-pointer" /><label htmlFor="forceFail" className="text-sm text-red-400 cursor-pointer flex items-center gap-1 font-semibold"><AlertTriangle className="w-4 h-4"/> Simulate Backend Failure (Triggers DLT)</label></div>
            <button onClick={publishMessage} className="bg-blue-600 hover:bg-blue-500 text-white px-6 py-2 rounded-lg flex items-center gap-2 font-bold transition-all transform active:scale-95 shadow-lg shadow-blue-900/50"><Send className="w-4 h-4" /> Publish to Topic</button>
          </div>
        </section>

        <div className="flex justify-center"><ArrowDown className="text-slate-600 w-8 h-8 animate-bounce" /></div>

        {/* STEP 2 */}
        <section className="bg-blue-950/30 border border-blue-900/50 rounded-xl p-6 shadow-inner relative">
          <div className="absolute -top-3 -left-3 bg-blue-500 text-white w-8 h-8 flex items-center justify-center rounded-full font-bold shadow">2</div>
          <div className="flex justify-between items-start mb-4">
            <h2 className="text-xl font-bold text-blue-300 flex items-center gap-2"><Database className="w-5 h-5"/> Core Topic (Message Broker)</h2>
            <div className="flex gap-2">
              <span className="bg-indigo-900 text-indigo-300 text-[10px] px-2 py-1 rounded border border-indigo-700 flex items-center gap-1"><Shield className="w-3 h-3"/> At-least-once (Default)</span>
              <span className="bg-purple-900 text-purple-300 text-[10px] px-2 py-1 rounded border border-purple-700 flex items-center gap-1"><Share2 className="w-3 h-3"/> Ordering Keys Supported</span>
            </div>
          </div>
          <div className="bg-slate-950 rounded p-3 h-32 overflow-y-auto border border-slate-800">
            {topicLog.length === 0 && <div className="text-sm text-slate-500 italic mt-8 text-center">Topic is empty. Waiting for publishers...</div>}
            {topicLog.map((m, i) => (
              <div key={i} className="text-xs mb-2 p-2 bg-slate-900 rounded border border-slate-800 flex justify-between items-center"><div className="flex gap-3 items-center"><span className="text-slate-500">[{m.timestamp}]</span><span className="bg-blue-900/50 text-blue-400 font-mono px-2 py-0.5 rounded text-[10px]">ID: {m.id}</span><span className="text-slate-300">{m.raw}</span></div>{m.orderKey && <span className="text-[10px] text-purple-400 border border-purple-800 px-1.5 rounded bg-purple-950/30">{m.orderKey}</span>}</div>
            ))}
          </div>
        </section>

        <div className="flex justify-center items-center gap-16 relative">
          <ArrowDown className="text-slate-600 w-8 h-8 -rotate-45 relative right-12" /><ArrowDown className="text-slate-600 w-8 h-8" /><ArrowDown className="text-slate-600 w-8 h-8 rotate-45 relative left-12" />
        </div>

        {/* STEP 3 & 4 */}
        <div className="grid grid-cols-1 md:grid-cols-2 gap-6 relative">
          <div className="absolute -top-8 -left-3 bg-teal-600 text-white w-8 h-8 flex items-center justify-center rounded-full font-bold shadow z-10">3</div>
          <div className="absolute -top-8 left-[50%] bg-purple-600 text-white w-8 h-8 flex items-center justify-center rounded-full font-bold shadow z-10">4</div>
          <section className="bg-slate-900 border border-slate-800 rounded-xl p-5 shadow-lg">
            <h3 className="text-lg font-bold text-teal-400 flex items-center gap-2 mb-2"><Activity className="w-5 h-5"/> Push Delivery Model</h3>
            <p className="text-xs text-slate-400 mb-4 h-8">Pub/Sub actively sends HTTPS POST requests to your endpoint immediately.</p>
            <div className="bg-slate-950 rounded p-2 h-40 overflow-y-auto border border-slate-800">
              {pushLog.length === 0 && <div className="text-xs text-slate-500 italic text-center mt-12">Listening on webhook URL...</div>}
              {pushLog.map((m, i) => (<div key={i} className="text-xs mb-2 p-2 bg-slate-900 rounded border border-slate-800 flex justify-between items-center"><div><div className="text-teal-400 font-bold mb-1">POST /api/webhook</div><div className="text-slate-400 font-mono text-[10px]">{m.id}</div></div><span className="bg-green-900/30 text-green-400 px-2 py-1 rounded flex items-center gap-1 border border-green-800/50"><CheckCircle className="w-3 h-3" /> 200 OK (Implicit ACK)</span></div>))}
            </div>
          </section>
          <section className="bg-slate-900 border border-slate-800 rounded-xl p-5 shadow-lg">
            <div className="flex justify-between items-start mb-2"><h3 className="text-lg font-bold text-purple-400 flex items-center gap-2"><RefreshCw className="w-5 h-5"/> Pull Delivery Model</h3><span className="bg-purple-900 text-purple-200 px-2 py-0.5 rounded text-xs font-bold border border-purple-700">Queue: {pullQueue.length}</span></div>
            <p className="text-xs text-slate-400 mb-4 h-8">Messages queue up until subscriber actively requests batches via gRPC/REST.</p>
            <div className="bg-slate-950 rounded p-2 h-24 overflow-y-auto border border-slate-800 mb-3">
              {pullQueue.length === 0 && <div className="text-xs text-slate-500 italic text-center mt-6">Queue is empty...</div>}
              {pullQueue.map((m, i) => (<div key={i} className="text-[10px] text-slate-400 font-mono p-1 border-b border-slate-800">UNACKED: {m.id}</div>))}
            </div>
            <button onClick={handlePullDelivery} disabled={pullQueue.length === 0} className={`w-full py-2 rounded text-sm font-bold flex items-center justify-center gap-2 transition-all ${pullQueue.length > 0 ? 'bg-purple-600 hover:bg-purple-500 text-white active:scale-95' : 'bg-slate-800 text-slate-600 cursor-not-allowed'}`}><RefreshCw className={`w-4 h-4 ${pullQueue.length > 0 ? 'animate-spin' : ''}`} /> Execute Pull & Send ACK</button>
          </section>
        </div>

        {/* STEP 5 & 6 */}
        <div className="grid grid-cols-1 md:grid-cols-2 gap-6 relative">
           <div className="absolute -top-3 -left-3 bg-orange-500 text-white w-8 h-8 flex items-center justify-center rounded-full font-bold shadow z-10">5</div>
           <div className="absolute -top-3 left-[50%] bg-blue-500 text-white w-8 h-8 flex items-center justify-center rounded-full font-bold shadow z-10">6</div>
          <section className="bg-slate-900 border border-slate-800 rounded-xl p-5 shadow-lg">
            <h3 className="text-lg font-bold text-orange-400 flex items-center gap-2 mb-2"><HardDrive className="w-5 h-5" /> Cloud Storage (Batch)</h3>
            <p className="text-xs text-slate-400 mb-3">Real polled data. Flushes when batch limits hit.</p>
            <div className="space-y-2 h-[152px] overflow-y-auto pr-1">
              {gcsFiles.length === 0 && <div className="text-xs text-slate-500 italic text-center mt-12">Polling actual GCS bucket...</div>}
              {gcsFiles.map((f, i) => (<div key={i} className="flex items-center justify-between bg-slate-950 p-2 rounded border border-slate-800"><div className="flex items-center gap-2"><FileText className="w-4 h-4 text-orange-300" /><div><div className="text-[10px] font-mono text-slate-300 truncate w-40">{f.filename}</div><div className="text-[9px] text-slate-500">{f.time}</div></div></div><div className="text-[10px] text-slate-400 bg-slate-900 px-1.5 py-0.5 rounded border border-slate-700">{f.size} B</div></div>))}
            </div>
          </section>
          <section className="bg-slate-900 border border-slate-800 rounded-xl p-5 shadow-lg">
            <h3 className="text-lg font-bold text-blue-400 flex items-center gap-2 mb-2"><Table className="w-5 h-5" /> BigQuery (Streaming)</h3>
            <p className="text-xs text-slate-400 mb-3">Real polled data. Immediate availability for SQL.</p>
            <div className="bg-slate-950 rounded border border-slate-800 overflow-hidden h-[152px]">
              <table className="w-full text-left text-[10px]"><thead className="bg-slate-900 text-slate-400"><tr><th className="p-2">Time</th><th className="p-2">Sensor</th><th className="p-2">Temp</th></tr></thead>
              <tbody>
                {bqLog.length === 0 && <tr><td colSpan="3" className="p-4 text-center text-slate-500 italic">Polling actual BQ table...</td></tr>}
                {bqLog.map((row, i) => (<tr key={i} className="border-t border-slate-800"><td className="p-2 text-slate-500">{row.time}</td><td className="p-2 text-blue-300 font-mono">{row.payload?.sensor_id || 'N/A'}</td><td className="p-2 text-green-400 font-mono">{row.payload?.temp || 'N/A'}</td></tr>))}
              </tbody></table>
            </div>
          </section>
        </div>

        <div className="flex justify-center"><ArrowDown className="text-red-900/50 w-8 h-8" /></div>

        {/* STEP 7 */}
        <section className="bg-red-950/20 border border-red-900/50 rounded-xl p-6 shadow-[0_0_20px_rgba(220,38,38,0.05)] relative">
          <div className="absolute -top-3 -left-3 bg-red-600 text-white w-8 h-8 flex items-center justify-center rounded-full font-bold shadow">7</div>
          <h2 className="text-xl font-bold text-red-400 flex items-center gap-2 mb-2"><AlertTriangle className="w-5 h-5"/> Dead Letter Topic (DLT)</h2>
          <p className="text-sm text-slate-400 mb-4">Captures un-acknowledgeable messages (NACKs) after maximum delivery attempts to prevent infinite loops.</p>
          <div className="bg-slate-950 rounded p-3 h-28 overflow-y-auto border border-red-900/30 grid grid-cols-1 md:grid-cols-2 gap-3">
            {dltLog.length === 0 && <div className="text-sm text-slate-600 italic col-span-2 text-center mt-6">No delivery failures detected.</div>}
            {dltLog.map((m, i) => (<div key={i} className="text-xs p-2 bg-red-900/10 border border-red-800/30 rounded flex flex-col justify-center"><div className="flex justify-between text-red-300 font-bold mb-1"><span>ID: {m.id}</span> <span className="bg-red-900 px-1 rounded text-[9px]">FAILED</span></div><div className="text-slate-400 text-[10px]">Reason: <span className="text-slate-300">{m.reason}</span></div><div className="text-slate-500 text-[10px] mt-1 font-mono truncate">{m.raw}</div></div>))}
          </div>
        </section>

        {/* STEP 8 */}
        <section className="bg-slate-900 border border-yellow-900/50 rounded-xl p-6 relative">
          <div className="absolute -top-3 -left-3 bg-yellow-600 text-white w-8 h-8 flex items-center justify-center rounded-full font-bold shadow">8</div>
          <div className="flex flex-col md:flex-row justify-between items-center gap-6">
            <div>
              <h2 className="text-xl font-bold text-yellow-400 flex items-center gap-2 mb-2"><DollarSign className="w-6 h-6"/> Cost & Pricing Model Summary</h2>
              <p className="text-sm text-slate-400 max-w-xl">Pub/Sub charges based on <strong>Data Volume</strong> (Throughput). The critical rule is that <span className="text-yellow-200">Quota is consumed in minimum 1kB units</span>. Notice how batching small messages saves you up to 90% of your billed quota compared to sending them individually.</p>
            </div>
            <div className="bg-slate-950 border border-slate-800 rounded-xl p-4 flex gap-6 w-full md:w-auto shadow-inner">
              <div className="text-center"><div className="text-xs text-slate-400 uppercase tracking-wider mb-1">Messages Sent</div><div className="text-3xl font-extrabold text-blue-400">{messageCount}</div></div>
              <div className="w-px bg-slate-800"></div>
              <div className="text-center"><div className="text-xs text-slate-400 uppercase tracking-wider mb-1">Total Billed</div><div className="text-3xl font-extrabold text-yellow-400">{billingKb} <span className="text-lg">kB</span></div></div>
            </div>
          </div>
        </section>

      </div>
    </div>
  );
}
EOF

cat << 'EOF' > frontend/nginx.conf
server {
    listen 8080;
    server_name localhost;
    location / {
        root   /usr/share/nginx/html;
        index  index.html index.htm;
        try_files $uri $uri/ /index.html;
    }
}
EOF

cat << 'EOF' > frontend/Dockerfile
FROM node:18-alpine AS builder
WORKDIR /app
COPY package*.json ./
RUN npm install
COPY . .
RUN npm run build

FROM nginx:alpine
COPY --from=builder /app/dist /usr/share/nginx/html
COPY nginx.conf /etc/nginx/conf.d/default.conf
EXPOSE 8080
CMD ["nginx", "-g", "daemon off;"]
EOF

echo -e "\n[9/10] Building & Deploying Frontend via Cloud Build..."
gcloud builds submit ./frontend --tag $FRONTEND_IMAGE

FRONTEND_URL=$(gcloud run deploy frontend-service \
    --image=$FRONTEND_IMAGE \
    --region=$REGION --service-account=$SA_EMAIL \
    --allow-unauthenticated --format='value(status.url)')

echo "=========================================================="
echo " DEPLOYMENT COMPLETE! "
echo "=========================================================="
echo "Frontend UI:    $FRONTEND_URL"
echo "Backend API:    $BACKEND_URL"
echo "BigQuery Table: ${PROJECT_ID}.${BQ_DATASET}.${BQ_TABLE}"
echo "Storage Bucket: gs://$GCS_BUCKET"
