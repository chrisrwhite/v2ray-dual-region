"""Generate a VMess URI and QR code from a V2Ray client config JSON.

Produces a vmess:// link that can be scanned by mobile V2Ray clients
(e.g. V2Box on iOS/Android).
"""

import argparse
import base64
import json
import sys
from pathlib import Path

import qrcode


def build_vmess_uri(config: dict, name: str) -> str:
    outbound = config["outbounds"][0]
    vnext = outbound["settings"]["vnext"][0]
    user = vnext["users"][0]
    stream = outbound.get("streamSettings", {})
    ws = stream.get("wsSettings", {})

    vmess_obj = {
        "v": "2",
        "ps": name,
        "add": vnext["address"],
        "port": str(vnext["port"]),
        "id": user["id"],
        "aid": str(user.get("alterId", 0)),
        "net": stream.get("network", "ws"),
        "type": "none",
        "host": ws.get("headers", {}).get("Host", ""),
        "path": ws.get("path", ""),
        "tls": "tls" if stream.get("security") == "tls" else "",
    }

    payload = json.dumps(vmess_obj, separators=(",", ":"))
    return "vmess://" + base64.urlsafe_b64encode(payload.encode()).decode()


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Generate a VMess QR code from a V2Ray client config."
    )
    parser.add_argument(
        "--config",
        default="terraform/client-config.json",
        help="Path to the V2Ray client-config.json (default: terraform/client-config.json)",
    )
    parser.add_argument(
        "--name",
        default="v2ray-dual-hop",
        help="Profile name shown in the V2Ray client app (default: v2ray-dual-hop)",
    )
    parser.add_argument(
        "--output",
        default="vmess_qr.png",
        help="Output path for the QR code image (default: vmess_qr.png)",
    )
    parser.add_argument(
        "--display",
        action="store_true",
        help="Print the QR code to the terminal instead of saving an image",
    )
    args = parser.parse_args()

    config_path = Path(args.config)
    if not config_path.exists():
        print(f"Error: config file not found: {config_path}", file=sys.stderr)
        print(
            "Run 'terraform/deploy.sh' first to generate the client config.",
            file=sys.stderr,
        )
        sys.exit(1)

    with open(config_path) as f:
        config = json.load(f)

    try:
        vmess_uri = build_vmess_uri(config, args.name)
    except (KeyError, IndexError) as exc:
        print(f"Error: could not parse config — {exc}", file=sys.stderr)
        sys.exit(1)

    print(f"VMess URI:\n  {vmess_uri}\n")

    if args.display:
        qr = qrcode.QRCode()
        qr.add_data(vmess_uri)
        qr.print_ascii(tty=sys.stdout.isatty())
    else:
        img = qrcode.make(vmess_uri)
        img.save(args.output)
        print(f"QR code saved to {args.output}")


if __name__ == "__main__":
    main()
