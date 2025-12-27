Here is the `README.md` file tailored for your repository. It covers the full lifecycle from launching the EC2 instance to troubleshooting the deployed stack.

---

# Self-Hosted n8n with Nginx, Auto-HTTPS, and S3 Backups

This repository contains a unified setup script to deploy a production-ready **n8n** instance on AWS EC2 (Ubuntu). It automatically handles:

* **Docker & Python 3 Installation**: Auto-installs dependencies if missing.
* **Reverse Proxy**: Uses **Nginx** to handle SSL termination (keeping n8n uninterrupted during cert renewals).
* **SSL Certificates**: Auto-generates wildcard certificates via **Let's Encrypt** (supports Cloudflare, Route53, Google Cloud DNS).
* **Backups**: Configures hourly backups of all workflows and data to **AWS S3**.

---

## 📋 Prerequisites

1. **AWS EC2 Instance**: Ubuntu 22.04 or 24.04 (t3.small or larger recommended).
2. **Domain Name**: A domain pointing to your server (or managed via Route53/Cloudflare/Google).
3. **AWS S3 Bucket**: A dedicated bucket for backups (e.g., `my-n8n-backups`).
4. **AWS IAM User**: A service user with read/write access to that specific bucket.

---

## 🚀 Installation Guide

### Step 1: AWS Environment Setup

#### 1. Launch EC2 Instance

Launch a fresh **Ubuntu** instance. Ensure your Security Group allows the following inbound traffic:

* **SSH (22)**: Your IP only.
* **HTTP (80)**: Anywhere (for initial Let's Encrypt validation).
* **HTTPS (443)**: Anywhere.

#### 2. Configure S3 & IAM

1. **Create an S3 Bucket** in your desired region.
2. **Create an IAM Policy**:
* Copy the contents of the `iam_policy.json` file included in this repository.
* Go to **AWS IAM > Policies > Create Policy** and paste the JSON.
* *Note: Replace `YOUR_BUCKET_NAME` in the JSON with your actual bucket name.*


3. **Create an IAM User**:
* Create a user (e.g., `n8n-backup-user`).
* Attach the policy you just created.
* Generate **Access Keys** (Access Key ID & Secret Access Key) and save them.



### Step 2: Bootstrap the Server

SSH into your new EC2 instance and prepare the environment by pulling this repository.

*(If you have a bootstrap script in this repo, run it now. Otherwise, use the commands below)*:

```bash
# Update package list and install Git
sudo apt update && sudo apt install -y git

# Clone the repository
git clone https://github.com/lftf-articles/n8n-setup.git

# Enter the directory
cd n8n-setup

```

### Step 3: Run the Setup Script

Make the script executable and run it. You can pass your details as arguments or follow the interactive prompts.

**Option A: Interactive Mode**

```bash
sudo chmod +x setup-n8n.sh
sudo ./setup-n8n.sh <your-domain> <timezone>
# Example: sudo ./setup-n8n.sh lftf.dev est

```

**Option B: One-Line Mode**

```bash
# Usage: sudo ./setup-n8n.sh <domain> <timezone> <email>
sudo ./setup-n8n.sh lftf.dev est myemail@example.com

```

**During the setup, you will be asked to:**

1. Confirm your **Access Domain** (e.g., `n8n.lftf.dev`).
2. Select your **DNS Provider** (Cloudflare, Route53, or Google) and provide API credentials for SSL generation.
3. Provide your **AWS S3 Access Keys** and **Bucket Name** for the backup service.

---

## 📂 File Structure

The script installs everything into `/root/n8n-docker` by default.

| Path | Description |
| --- | --- |
| **`/root/n8n-docker/`** | **Project Root**. Contains all configurations. |
| `docker-compose.yaml` | Defines the n8n, Nginx, and Backup services. |
| `nginx_conf/default.conf` | Nginx configuration file (reverse proxy & WebSocket settings). |
| **`local-files/`** | Mapped to `/files` inside n8n. **Save your read/write files here.** |
| `/root/.secrets/` | Stores DNS API tokens for Certbot auto-renewal. |

---

## 🛠️ Troubleshooting

### 1. Check Service Logs

If n8n isn't loading, check the logs for specific services.

```bash
cd /root/n8n-docker

# View all logs
docker compose logs -f

# View n8n logs only
docker compose logs -f n8n

# View Nginx logs
docker compose logs -f nginx

# View Backup logs
docker compose logs -f backup

```

### 2. Nginx Issues

If you get a "502 Bad Gateway," n8n might still be starting up, or the connection is blocked.

```bash
# Reload Nginx configuration
docker compose exec nginx nginx -s reload

# Test Nginx config syntax
docker compose exec nginx nginx -t

```

### 3. Permissions Issues

If n8n cannot read/write files in the `/files` node:

```bash
# Ensure the local-files directory is owned by user 1000 (node)
sudo chown -R 1000:1000 /root/n8n-docker/local-files

```

### 4. SSL Certificate Renewal

Certificates renew automatically. To test the renewal hook manually:

```bash
sudo certbot renew --dry-run

```

*If successful, this will trigger the hook that reloads Nginx automatically.*