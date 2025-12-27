#!/bin/bash
# ================================================
# Ubuntu EC2 Bootstrap: SSM Agent + Git + Repo Pull
# ================================================

set -e  # Exit on any error

# -----------------------------
# 1. Update system and install basics
# -----------------------------
apt-get update
apt-get install -y snapd git

# -----------------------------
# 2. Install & configure AWS SSM Agent (candidate channel)
# -----------------------------
if ! snap list amazon-ssm-agent >/dev/null 2>&1; then
    snap install amazon-ssm-agent --classic
fi

snap switch --channel=candidate amazon-ssm-agent
snap refresh amazon-ssm-agent

snap start amazon-ssm-agent || true
snap enable amazon-ssm-agent || true

# Workaround for occasional Snap timeout issue
systemctl restart snap.amazon-ssm-agent.amazon-ssm-agent.service || true

echo "SSM Agent installation and configuration complete." | tee /var/log/ssm-bootstrap.log

# -----------------------------
# 3. Clone your setup scripts repository
# -----------------------------
REPO_URL="https://github.com/lftf-articles/n8n-setup.git"

# Directory where you want the scripts (common choices: /opt/setup or /root/setup)
CLONE_DIR="/opt/setup-scripts"

echo "Cloning setup scripts from $REPO_URL into $CLONE_DIR..."

mkdir -p "$CLONE_DIR"
git clone "$REPO_URL" "$CLONE_DIR"

# Optional: Make all .sh files executable
find "$CLONE_DIR" -type f -name "*.sh" -exec chmod +x {} \; 2>/dev/null || true

echo "Repository cloned successfully to $CLONE_DIR"

# -----------------------------
# 4. Verification
# -----------------------------
echo "=== SSM Agent Status ==="
snap services amazon-ssm-agent
snap info amazon-ssm-agent | grep tracking

echo "=== Git Clone Contents ==="
ls -la "$CLONE_DIR"

echo "Bootstrap complete!" | tee -a /var/log/ssm-bootstrap.log