#!/bin/bash
set -euo pipefail

echo "Setting up exit node..."

sudo apt update -y
sudo apt install -y docker.io docker-compose

sudo systemctl enable --now docker

sudo mkdir -p /opt/v2ray/config
cd /opt/v2ray

UUID=$(grep '^UUID=' /home/ubuntu/.env | cut -d '=' -f2)

# V2Ray config: accept forwarded traffic from relay, egress to internet
cat > config/config.json <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "port": 10000,
      "protocol": "vmess",
      "settings": {
        "clients": [
          {
            "id": "$UUID",
            "alterId": 0,
            "security": "auto"
          }
        ]
      },
      "streamSettings": {
        "network": "tcp"
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "settings": {}
    }
  ]
}
EOF

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
EOF

sudo docker-compose up -d

echo "Exit node ready. Listening on port 10000."
