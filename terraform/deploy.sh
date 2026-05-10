#!/bin/bash
set -euo pipefail

SERVER_KEY_PATH="v2ray-vpn-keypair.pem"
SERVER_USER="ubuntu"
LOCAL_CONFIG_DEST="./client-config.json"
REMOTE_CONFIG_PATH="/opt/v2ray/client-config.json"

echo "Destroying any existing Terraform resources..."
terraform destroy -auto-approve || true

echo "Running Terraform init and apply..."
terraform init
terraform apply -auto-approve -parallelism=1

echo "Exporting EC2 private key..."
chmod u+w "$SERVER_KEY_PATH" || true
terraform output -raw private_key > "$SERVER_KEY_PATH"
chmod 400 "$SERVER_KEY_PATH"

RELAY_IP="$(terraform output -raw relay_ip)"
echo "Relay node IP: ${RELAY_IP}"

echo "Waiting 60s for provisioning to complete..."
sleep 60

echo "Downloading client config from relay node..."
scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -i "$SERVER_KEY_PATH" \
    "$SERVER_USER@$RELAY_IP:$REMOTE_CONFIG_PATH" \
    "$LOCAL_CONFIG_DEST"

echo "Done! Import-ready config: $LOCAL_CONFIG_DEST"
echo ""
echo "Generate a QR code for mobile import:"
echo " poetry run python generate_vmess_config_qr.py"
