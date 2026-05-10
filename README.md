# v2ray-dual-region

I built this before a trip abroad where I knew I'd be running into network restrictions blocking access to everyday tools such as GitHub, Google, basically anything I needed to work. Rather than relying on a single commercial VPN (which are often blocked or throttled in restrictive networks), I wanted to understand the problem at the protocol level and build something I actually controlled. The result is a two-hop setup where traffic enters one region, hops through an encrypted tunnel, and exits cleanly from another which is harder to fingerprint than a single-endpoint VPN, and fully mine to debug when something breaks at 2am in a hotel room.

A Python-based QR code generator is included for easy mobile client setup.

## Architecture

See [ARCHITECTURE.md](ARCHITECTURE.md) for detailed diagrams.

```
Client (SOCKS5) ──WSS──▶ Relay (Region A) ──VMess/TCP──▶ Exit (Region B) ──▶ Internet
```

## Technologies

| Category | Tools |
|----------|-------|
| Infrastructure | Terraform, AWS EC2, Elastic IP, Security Groups |
| Networking | V2Ray (VMess), Nginx reverse proxy, WebSocket, TLS |
| Certificates | Certbot, Let's Encrypt, Cloudflare DNS-01 challenge |
| Containers | Docker, Docker Compose |
| Tooling | Python, qrcode (QR code generator) |

## Prerequisites

- [AWS CLI v2](https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html) configured with credentials
- [Terraform >= 1.3](https://developer.hashicorp.com/terraform/install)
- A domain with DNS managed by [Cloudflare](https://www.cloudflare.com/)
- A Cloudflare API token with `Zone:DNS:Edit` permission
- Python 3.13+ and [Poetry](https://python-poetry.org/) (for the QR code generator)
- Docker and Docker Compose (installed automatically on EC2 by the setup scripts)

## Quick Start

### 1. Clone and configure

```bash
git clone https://github.com/YOUR_USERNAME/v2ray-dual-region.git
cd v2ray-dual-region
cp .env.example .env
```

Edit `.env` with your values:

```env
UUID=<run: uuidgen>
SERVER_DOMAIN=vpn.example.com
CF_API_EMAIL=you@example.com
CF_API_TOKEN=<your-cloudflare-api-token>
```

### 2. Set Terraform variables

Create `terraform/terraform.tfvars`:

```hcl
trusted_ip  = "YOUR_PUBLIC_IP"      # run: curl -4 -s ifconfig.me
ami_relay = "ami-xxxxxxxxxxxxxxxxx"   # Ubuntu 22.04 LTS — find yours at ubuntu.com/aws
ami_exit  = "ami-xxxxxxxxxxxxxxxxx"   # Ubuntu 22.04 LTS — find yours at ubuntu.com/aws
relay_region = "your-relay-region"   # e.g. eu-west-1, us-west-2
exit_region  = "your-exit-region"    # e.g. us-east-1, ap-southeast-1
```

### 3. Point your domain to Cloudflare DNS

Before deploying, your domain must be set up in Cloudflare so that Certbot can
use the DNS-01 challenge to obtain a TLS certificate.

1. Log in to [Cloudflare](https://dash.cloudflare.com) and add your domain (or
   use an existing one).
2. Go to **DNS > Records** and create an `A` record:
   - **Name**: the subdomain from your `.env` `SERVER_DOMAIN` (e.g. `vpn` for
     `vpn.example.com`)
   - **IPv4 address**: any placeholder like `1.2.3.4` (you'll update this after
     deploy)
   - **Proxy status**: **DNS only** (grey cloud) -- V2Ray traffic must not pass
     through the Cloudflare proxy
3. Create a Cloudflare API token at **My Profile > API Tokens > Create Token**:
   - Use the **Edit zone DNS** template
   - Scope it to the specific zone (domain) you're using
   - Copy the token into your `.env` as `CF_API_TOKEN`

### 4. Deploy

```bash
cd terraform
chmod +x deploy.sh
./deploy.sh
```

This will:
- Provision two EC2 instances with Elastic IPs
- Install Docker and V2Ray on both nodes
- Obtain a TLS certificate via Cloudflare DNS-01 challenge
- Configure Nginx as a TLS-terminating reverse proxy on the relay
- Download a ready-to-import `client-config.json`

### 5. Update Cloudflare DNS with the relay IP

After `deploy.sh` completes, it prints the relay node's Elastic IP. Update your
Cloudflare `A` record to point to it:

```bash
# Get the relay IP from Terraform output
cd terraform
terraform output relay_ip
```

Then in Cloudflare **DNS > Records**:
1. Edit the `A` record you created in step 3
2. Set **IPv4 address** to the relay Elastic IP from the output above
3. Confirm **Proxy status** is still **DNS only** (grey cloud)

You can verify DNS is resolving correctly:

```bash
dig +short vpn.example.com
# Should return the relay Elastic IP
```

### 6. Connect

After deployment you have a `terraform/client-config.json` containing the VMess
connection profile. Import it into any V2Ray-compatible client using one of the
methods below.

#### Desktop -- v2rayN (Windows) or v2rayN (macOS)

1. Download [v2rayN](https://github.com/2dust/v2rayN/releases) and launch it.
2. Go to **Servers > Add VMess server**.
3. Fill in the fields from `client-config.json`:
   - **Address**: your `SERVER_DOMAIN` (e.g. `vpn.example.com`)
   - **Port**: `443`
   - **UUID**: the `id` value from the config
   - **AlterID**: `0`
   - **Security**: `auto`
   - **Network**: `ws`
   - **TLS**: `tls`
   - **WebSocket path**: `/stream`
   - **Host**: your `SERVER_DOMAIN`
4. Click **OK**, then right-click the server and select **Set as active server**.
5. Enable the system proxy from the v2rayN tray icon.

Alternatively, import via VMess URI:

1. Generate the URI with the QR code tool (see below).
2. Copy the `vmess://...` string printed to the console.
3. In v2rayN, go to **Servers > Import from clipboard** (or press `Ctrl+V` in
   the server list).

#### iOS / Android -- v2Box

1. Install [v2Box](https://apps.apple.com/app/v2box-v2ray-client/id6446814690)
   from the App Store.
2. Generate a QR code on your computer (see below).
3. In v2Box, tap **+** > **Scan QR Code** and scan the QR image.
4. The server profile is imported automatically. Tap it to connect.

To import without a QR code:

1. Copy the `vmess://...` URI to your clipboard.
2. In v2Box, tap **+** > **Import from Clipboard**.

#### Verify the connection

Once connected through any client, confirm your traffic exits through the VPN:

```bash
curl -x socks5h://localhost:1080 https://ifconfig.me
```

The returned IP should match the exit node's Elastic IP (check with
`terraform output exit_ip`).

## QR Code Generator

Generate a VMess URI and QR code for mobile client import:

```bash
# Install dependencies
poetry install --no-root

# Save QR code as a PNG image
poetry run python generate_vmess_config_qr.py --config terraform/client-config.json

# Display QR code in the terminal (useful for scanning directly)
poetry run python generate_vmess_config_qr.py --config terraform/client-config.json --display

# Custom profile name (shows up in the client app)
poetry run python generate_vmess_config_qr.py --config terraform/client-config.json --name "my-vpn"
```

## Project Structure

```
v2ray-dual-region/
  .env.example                  # Template for required secrets
  .gitignore
  README.md
  ARCHITECTURE.md               # Detailed diagrams and component docs
  pyproject.toml                # Python dependencies (QR generator)
  generate_vmess_config_qr.py   # VMess QR code generator
  terraform/
    provider.tf                 # Terraform version constraints
    variables.tf                # Configurable inputs (regions, AMIs, IP)
    main.tf                     # EC2, EIP, SG, provisioners
    deploy.sh                   # One-command deploy + config download
  server/
    scripts/
      setup-relay.sh            # Relay node provisioning (V2Ray + Nginx + TLS)
      setup-exit.sh             # Exit node provisioning (V2Ray)
```

## Teardown

```bash
cd terraform
terraform destroy -auto-approve
```

## Security Notes

- SSH access is restricted to the IP specified in `trusted_ip`. Update it if your IP changes.
- The exit node's V2Ray port (10000) only accepts traffic from the relay node's Elastic IP.
- TLS certificates are obtained via DNS-01 challenge and auto-renewed via cron.
- All secrets (`.env`, `*.pem`, `terraform.tfvars`, `client-config.json`) are gitignored.
- The relay node serves a static decoy page at `/` so the domain appears to host a normal website.

## License

MIT
