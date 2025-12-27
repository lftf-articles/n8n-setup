#!/bin/bash

# ==========================================
# n8n + Nginx + Certbot (Multi-Provider)
# ==========================================

# 1. INPUT PARSING
DOMAIN=$1
TIMEZONE_INPUT=$2
EMAIL_INPUT=$3

if [ -z "$DOMAIN" ]; then
    echo "Error: Domain is required."
    echo "Usage: sudo ./setup-n8n.sh <domain> [est|pst|cst] [email]"
    exit 1
fi

# Determine Timezone (Default to EST)
case $(echo "$TIMEZONE_INPUT" | tr '[:upper:]' '[:lower:]') in
    pst) TZ_VAL="America/Los_Angeles"; echo "Timezone: PST";;
    cst) TZ_VAL="America/Chicago"; echo "Timezone: CST";;
    est) TZ_VAL="America/New_York"; echo "Timezone: EST";;
    *)   TZ_VAL="America/New_York"; echo "Default Timezone: EST";;
esac

# Handle Email Input
if [ -z "$EMAIL_INPUT" ]; then
    echo ""
    read -p "Enter your Email Address (for Let's Encrypt renewal): " EMAIL_INPUT
fi

if [ -z "$EMAIL_INPUT" ]; then
    echo "Error: Email is required for SSL registration."
    exit 1
fi

EMAIL="$EMAIL_INPUT"

# Handle Access Domain Input
echo ""
echo "------------------------------------------------"
echo "Configuration for: $DOMAIN"
echo "------------------------------------------------"
echo "This script generates a wildcard certificate for *.$DOMAIN"
echo "You can choose the specific subdomain to access n8n."
echo "Examples: n8n.$DOMAIN, flow.$DOMAIN, automation.$DOMAIN"
read -p "Enter full Access Domain (default: n8n.$DOMAIN): " ACCESS_DOMAIN_INPUT
ACCESS_DOMAIN=${ACCESS_DOMAIN_INPUT:-n8n.$DOMAIN}

echo "-> n8n will be accessible at: https://$ACCESS_DOMAIN"

# DEFINING THE PROJECT ROOT
PROJECT_DIR="/root/n8n-docker"
SECRETS_DIR="/root/.secrets"

# ==========================================
# 2. SYSTEM DEPENDENCIES (Docker & Python)
# ==========================================

echo ""
echo "------------------------------------------------"
echo "Checking System Dependencies..."
echo "------------------------------------------------"

# Update package list once for all checks
apt-get update

# CHECK: PYTHON 3
if ! command -v python3 &> /dev/null; then
    echo "Python 3 not found. Installing..."
    apt-get install -y python3 python3-pip
    echo "Python 3 installed successfully."
else
    echo "Python 3 is already installed."
fi

# CHECK: DOCKER
if ! command -v docker &> /dev/null; then
    echo "Docker not found. Installing Docker & Docker Compose for Ubuntu..."
    
    # Install prereqs
    apt-get install -y ca-certificates curl gnupg

    # Add Docker's official GPG key
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg

    # Set up the repository
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
      $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
      tee /etc/apt/sources.list.d/docker.list > /dev/null

    # Install Docker Engine
    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    echo "Docker installed successfully!"
else
    echo "Docker is already installed. Proceeding..."
fi

# ==========================================
# 3. PROVIDER SELECTION (SSL)
# ==========================================

echo ""
echo "Select your DNS Provider for SSL Validation:"
echo "1) Cloudflare"
echo "2) AWS Route53"
echo "3) Google Cloud DNS"
read -p "Enter number (1-3): " PROVIDER_CHOICE

# Base Certbot Install
echo "Installing Core Certbot..."
apt-get install snapd -y
snap install core && snap refresh core
snap install --classic certbot
ln -sf /snap/bin/certbot /usr/bin/certbot
snap set certbot trust-plugin-with-root=ok
mkdir -p "$SECRETS_DIR"

# ==========================================
# 4. SSL CERTIFICATE GENERATION
# ==========================================

case $PROVIDER_CHOICE in
    1) # CLOUDFLARE
        echo "Installing Cloudflare Plugin..."
        snap install certbot-dns-cloudflare
        
        echo ""
        echo "Enter your Cloudflare API Token (Zone:DNS:Edit permission):"
        read -p "Token: " CF_TOKEN
        
        cat <<EOF > "$SECRETS_DIR/cloudflare.ini"
dns_cloudflare_api_token = $CF_TOKEN
EOF
        chmod 600 "$SECRETS_DIR/cloudflare.ini"

        echo "Issuing Certificate via Cloudflare..."
        certbot certonly \
          --dns-cloudflare \
          --dns-cloudflare-credentials "$SECRETS_DIR/cloudflare.ini" \
          -d "*.$DOMAIN" -d "$DOMAIN" \
          --email "$EMAIL" --agree-tos --non-interactive
        ;;

    2) # AWS ROUTE53
        echo "Installing Route53 Plugin..."
        snap install certbot-dns-route53
        
        echo ""
        echo "Enter AWS Access Key ID (User needs Route53 permissions):"
        read -p "Access Key ID: " ROUTE53_KEY
        echo "Enter AWS Secret Access Key:"
        read -p "Secret Access Key: " ROUTE53_SECRET

        # For the Route53 snap plugin, we export vars immediately before running
        echo "Issuing Certificate via Route53..."
        AWS_ACCESS_KEY_ID="$ROUTE53_KEY" \
        AWS_SECRET_ACCESS_KEY="$ROUTE53_SECRET" \
        certbot certonly \
          --dns-route53 \
          -d "*.$DOMAIN" -d "$DOMAIN" \
          --email "$EMAIL" --agree-tos --non-interactive
        ;;

    3) # GOOGLE CLOUD DNS
        echo "Installing Google Cloud DNS Plugin..."
        snap install certbot-dns-google
        
        echo ""
        echo "Setup required: You need a Service Account JSON key with 'DNS Administrator' role."
        echo "Please paste the ENTIRE contents of your Google JSON key file below."
        echo "Press Enter, paste the JSON, then press Ctrl+D to save."
        
        cat > "$SECRETS_DIR/google.json"
        chmod 600 "$SECRETS_DIR/google.json"
        
        echo "Issuing Certificate via Google Cloud DNS..."
        certbot certonly \
          --dns-google \
          --dns-google-credentials "$SECRETS_DIR/google.json" \
          -d "*.$DOMAIN" -d "$DOMAIN" \
          --email "$EMAIL" --agree-tos --non-interactive
        ;;

    *)
        echo "Invalid selection. Exiting."
        exit 1
        ;;
esac

# Check if cert success
if [ ! -d "/etc/letsencrypt/live/$DOMAIN" ]; then
    echo "Error: Certificate generation failed. Please check inputs and try again."
    exit 1
fi

# ==========================================
# 5. S3 BACKUP CONFIGURATION
# ==========================================

echo ""
echo "------------------------------------------------"
echo "S3 Backup Configuration"
echo "------------------------------------------------"
echo "We need to configure the hourly S3 backup service."
echo "Do you need help generating the IAM Policy for your backup user?"
echo "1) Yes, guide me and generate the policy."
echo "2) No, I already have my S3 Access Key and Secret."
read -p "Enter choice (1 or 2): " IAM_CHOICE

if [ "$IAM_CHOICE" -eq 1 ]; then
    echo ""
    read -p "Enter the EXACT name of your S3 Bucket (e.g., my-n8n-backup-bucket): " S3_BUCKET_NAME
    
    echo ""
    echo "============================================================"
    echo "STEP 1: Create an IAM Policy in AWS"
    echo "============================================================"
    echo "Go to AWS IAM -> Policies -> Create Policy -> JSON"
    echo "Paste the following JSON exactly:"
    echo ""
    cat <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "s3:ListBucket"
            ],
            "Resource": "arn:aws:s3:::$S3_BUCKET_NAME"
        },
        {
            "Effect": "Allow",
            "Action": [
                "s3:PutObject",
                "s3:GetObject",
                "s3:DeleteObject"
            ],
            "Resource": "arn:aws:s3:::$S3_BUCKET_NAME/*"
        }
    ]
}
EOF
    echo ""
    echo "============================================================"
    echo "STEP 2: Create an IAM User & Attach Policy"
    echo "============================================================"
    echo "1. Go to AWS IAM -> Users -> Create User (e.g., 'n8n-backup-user')."
    echo "2. Attach the policy you just created."
    echo "3. Create an Access Key for this user."
    echo "============================================================"
    echo ""
    echo "Once you have the Access Key ID and Secret, press Enter to continue..."
    read -r
else
    # If they said No, we still need the bucket name
    read -p "Enter your S3 Bucket Name: " S3_BUCKET_NAME
fi

echo ""
echo "Enter the IAM Access Key ID for the Backup User:"
read -p "Access Key ID: " S3_ACCESS_KEY
echo "Enter the IAM Secret Access Key:"
read -p "Secret Access Key: " S3_SECRET_KEY

# Default region if not provided
S3_REGION="us-east-1"
read -p "Enter S3 Bucket Region [Default: us-east-1]: " INPUT_REGION
S3_REGION=${INPUT_REGION:-$S3_REGION}

# ==========================================
# 6. NGINX & PROJECT CONFIG
# ==========================================

echo "Creating project directories in $PROJECT_DIR..."
mkdir -p "$PROJECT_DIR/nginx_conf"
mkdir -p "$PROJECT_DIR/local-files"

# Fix permissions for local-files so the container user (1000) can write to it
echo "Setting permissions for local-files..."
chown -R 1000:1000 "$PROJECT_DIR/local-files" 2>/dev/null || echo "Warning: Could not chown local-files. You may need to fix permissions manually if using non-root container user."

echo "Generating Nginx Config..."
cat <<EOF > "$PROJECT_DIR/nginx_conf/default.conf"
server {
    listen 80;
    server_name $ACCESS_DOMAIN;
    location / {
        # Redirect HTTP to HTTPS
        # We use \$ here so the script doesn't replace these variables
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl;
    server_name $ACCESS_DOMAIN;

    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    client_max_body_size 50M;
    
    location / {
        proxy_pass http://n8n:5678;

        # We use \$ here so the script passes the literal text "$host" to Nginx
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_buffering off;
    }
}
EOF

# ==========================================
# 7. DOCKER COMPOSE CONFIG
# ==========================================

echo "Generating docker-compose.yaml in $PROJECT_DIR..."
cat <<EOF > "$PROJECT_DIR/docker-compose.yaml"
version: '3.8'

services:
  n8n:
    image: docker.n8n.io/n8nio/n8n
    restart: always
    environment:
      - N8N_HOST=$ACCESS_DOMAIN
      - N8N_PORT=5678
      - N8N_PROTOCOL=https
      - N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS=true
      - NODE_ENV=production
      - WEBHOOK_URL=https://$ACCESS_DOMAIN/
      - GENERIC_TIMEZONE=$TZ_VAL
      - TZ=$TZ_VAL
    volumes:
      - n8n_data:/home/node/.n8n
      - ./local-files:/files

  nginx:
    image: nginx:alpine
    restart: always
    ports:
      - "443:443"
    volumes:
      - ./nginx_conf/default.conf:/etc/nginx/conf.d/default.conf:ro
      - /etc/letsencrypt/live/$DOMAIN/fullchain.pem:/etc/letsencrypt/live/$DOMAIN/fullchain.pem:ro
      - /etc/letsencrypt/live/$DOMAIN/privkey.pem:/etc/letsencrypt/live/$DOMAIN/privkey.pem:ro
    depends_on:
      - n8n

  backup:
    image: peterrus/s3-cron-backup:latest
    restart: always
    environment:
      - AWS_ACCESS_KEY_ID=$S3_ACCESS_KEY
      - AWS_SECRET_ACCESS_KEY=$S3_SECRET_KEY
      - AWS_DEFAULT_REGION=$S3_REGION
      - S3_BUCKET_URL=s3://$S3_BUCKET_NAME/
      - CRON_SCHEDULE=0 * * * *
      - BACKUP_NAME=n8n-full-backup
      - TARGET=/data
    volumes:
      - n8n_data:/data/n8n_data:ro
      - ./local-files:/data/local-files:ro

volumes:
  n8n_data:
EOF

# ==========================================
# 8. RENEWAL HOOK
# ==========================================

echo "Setting up Certificate Renewal Hook..."
mkdir -p /etc/letsencrypt/renewal-hooks/deploy

cat <<EOF > /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh
#!/bin/bash
cd $PROJECT_DIR
docker compose exec nginx nginx -s reload
EOF

chmod +x /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh

echo ""
echo "=========================================="
echo "          SETUP COMPLETE          "
echo "=========================================="
echo ""
echo "Your n8n environment has been created successfully."
echo ""
echo "📂 FILE LOCATIONS:"
echo "------------------------------------------"
echo "1. Project Root:      $PROJECT_DIR"
echo "2. Docker Compose:    $PROJECT_DIR/docker-compose.yaml"
echo "3. Nginx Config:      $PROJECT_DIR/nginx_conf/default.conf"
echo "4. Local Files:       $PROJECT_DIR/local-files/"
echo "   (Mapped to '/files' inside n8n. Use this for reading/writing files)"
echo "5. Database Volume:   n8n_data (Docker Named Volume)"
echo "   (Stored in: /var/lib/docker/volumes/n8n_data/_data)"
echo ""
echo "🚀 NEXT STEPS:"
echo "------------------------------------------"
echo "1. Navigate to the project directory:"
echo "   cd $PROJECT_DIR"
echo ""
echo "2. Start the services:"
echo "   docker compose up -d"
echo ""
echo "3. Access n8n at:"
echo "   https://$ACCESS_DOMAIN"