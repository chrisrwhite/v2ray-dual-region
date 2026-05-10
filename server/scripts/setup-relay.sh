#!/bin/bash
set -euo pipefail

# Load secrets from .env
set -a
source /home/ubuntu/.env
set +a

DOMAIN="$SERVER_DOMAIN"
EMAIL="$CF_API_EMAIL"
TOKEN="$CF_API_TOKEN"
EXIT_IP="${EXIT_NODE_IP:-}"

sudo apt update -y
sudo apt install -y docker.io docker-compose certbot

sudo systemctl enable --now docker

sudo mkdir -p /opt/v2ray/config /opt/v2ray/nginx/cert /opt/v2ray/nginx/conf.d /opt/v2ray/nginx/html
cd /opt/v2ray

UUID=$(grep '^UUID=' /home/ubuntu/.env | cut -d '=' -f2)
ALTER_ID=0

# --- TLS certificate via Cloudflare DNS challenge ---

if systemctl is-active --quiet nginx; then
  sudo systemctl stop nginx
fi

echo "Waiting for EC2 networking to stabilize..."
sleep 30

sudo mkdir -p /etc/letsencrypt
sudo tee /etc/letsencrypt/cloudflare.ini > /dev/null <<EOF
dns_cloudflare_api_token = $CF_API_TOKEN
EOF
sudo chmod 600 /etc/letsencrypt/cloudflare.ini

sudo apt install -y python3-certbot-dns-cloudflare

sudo certbot certonly \
  --dns-cloudflare \
  --dns-cloudflare-credentials /etc/letsencrypt/cloudflare.ini \
  --non-interactive \
  --agree-tos \
  --email "$EMAIL" \
  -d "$DOMAIN"

sudo cp /etc/letsencrypt/live/$DOMAIN/fullchain.pem ./nginx/cert/fullchain.pem
sudo cp /etc/letsencrypt/live/$DOMAIN/privkey.pem ./nginx/cert/privkey.pem

# --- V2Ray relay config ---
# Accepts client connections via WebSocket and forwards to the exit node.

cat > config/config.json <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "port": 10000,
      "listen": "127.0.0.1",
      "protocol": "vmess",
      "settings": {
        "clients": [
          {
            "id": "$UUID",
            "alterId": $ALTER_ID,
            "security": "auto"
          }
        ],
        "disableInsecureEncryption": false
      },
      "streamSettings": {
        "network": "ws",
        "security": "none",
        "wsSettings": {
          "path": "/stream",
          "headers": { "Host": "$DOMAIN" }
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "vmess",
      "tag": "exit-node",
      "settings": {
        "vnext": [
          {
            "address": "$EXIT_IP",
            "port": 10000,
            "users": [
              {
                "id": "$UUID",
                "alterId": $ALTER_ID,
                "security": "auto"
              }
            ]
          }
        ]
      },
      "streamSettings": {
        "network": "tcp"
      }
    }
  ],
  "routing": {
    "rules": [
      {
        "type": "field",
        "outboundTag": "exit-node",
        "port": "0-65535"
      }
    ]
  }
}
EOF

# --- Nginx: TLS termination + WebSocket reverse proxy ---

cat > nginx/html/index.html <<'HTMLEOF'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <title>Status Page</title>
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <style>
    body { font-family: Georgia, serif; max-width: 700px; margin: 40px auto; color: #333; background: #f9f9f9; padding: 0 20px; }
    h1 { font-size: 2.5em; margin-bottom: 0.1em; }
    h2 { color: #666; font-size: 1.2em; margin-top: 0; font-weight: normal; }
    article { margin-bottom: 2em; border-bottom: 1px solid #ccc; padding-bottom: 1em; }
    footer { margin-top: 2em; font-size: 0.9em; color: #999; text-align: center; }
  </style>
</head>
<body>
  <h1>Infrastructure Status</h1>
  <h2>Service health and updates</h2>

  <article>
    <h3>All Systems Operational</h3>
    <p>Services are running normally. No incidents to report.</p>
  </article>

  <footer>
    Status Page
  </footer>
</body>
</html>
HTMLEOF

sudo tee /opt/v2ray/nginx/html/robots.txt > /dev/null <<EOF
User-agent: *
Disallow: /
EOF

cat > nginx/conf.d/default.conf <<EOF
server {
    listen 443 ssl;
    server_name $DOMAIN;

    ssl_certificate /etc/nginx/cert/fullchain.pem;
    ssl_certificate_key /etc/nginx/cert/privkey.pem;

    location / {
        root /usr/share/nginx/html;
        index index.html;
        try_files \$uri \$uri/ =404;
    }

    location /stream {
        proxy_redirect off;
        proxy_pass http://127.0.0.1:10000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
    }
}

server {
    listen 80;
    server_name $DOMAIN;
    return 301 https://\$host\$request_uri;
}
EOF

# --- Docker Compose ---

cat > docker-compose.yml <<EOF
version: "3.8"
services:
  v2ray:
    image: v2fly/v2fly-core:v4.45.2
    container_name: v2ray
    restart: unless-stopped
    network_mode: host
    volumes:
      - ./config:/etc/v2ray
  nginx:
    image: nginx:latest
    container_name: nginx
    restart: unless-stopped
    network_mode: host
    volumes:
      - ./nginx/html:/usr/share/nginx/html
      - ./nginx/conf.d:/etc/nginx/conf.d
      - ./nginx/cert:/etc/nginx/cert
EOF

sudo docker-compose up -d

# --- Generate client config for import into V2Ray clients ---

cat > /opt/v2ray/client-config.json <<EOF
{
  "log": { "loglevel": "warning" },
  "dns": {
    "servers": ["1.1.1.1", "8.8.8.8"],
    "queryStrategy": "UseIPv4"
  },
  "inbounds": [
    {
      "port": 1080,
      "listen": "127.0.0.1",
      "protocol": "socks",
      "settings": { "auth": "noauth", "udp": true }
    }
  ],
  "outbounds": [
    {
      "protocol": "vmess",
      "tag": "relay",
      "settings": {
        "vnext": [
          {
            "address": "$DOMAIN",
            "port": 443,
            "users": [
              {
                "id": "$UUID",
                "alterId": $ALTER_ID,
                "security": "auto"
              }
            ]
          }
        ]
      },
      "streamSettings": {
        "network": "ws",
        "security": "tls",
        "wsSettings": {
          "path": "/stream",
          "headers": { "Host": "$DOMAIN" }
        }
      }
    }
  ]
}
EOF

echo "Setup complete!"
echo "Domain: $DOMAIN"
echo "Config: /opt/v2ray/config/config.json"

# Automatic TLS renewal
echo -e "\n0 3 * * * root certbot renew --quiet --deploy-hook 'docker restart nginx' >> /var/log/certbot-renew.log 2>&1" | sudo tee -a /etc/crontab > /dev/null
