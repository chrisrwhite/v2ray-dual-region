provider "aws" {
  alias  = "relay"
  region = var.relay_region
}

provider "aws" {
  alias  = "exit"
  region = var.exit_region
}

# ---------------------------------------------------------------------------
# SSH key pair (shared across both nodes)
# ---------------------------------------------------------------------------

resource "tls_private_key" "v2ray_vpn_key" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "local_file" "v2ray_private_key_pem" {
  filename        = "${path.module}/v2ray-vpn-keypair.pem"
  content         = tls_private_key.v2ray_vpn_key.private_key_pem
  file_permission = "0400"
}

# ---------------------------------------------------------------------------
# Relay node (entry point, terminates TLS, forwards to exit)
# ---------------------------------------------------------------------------

resource "aws_key_pair" "relay_key" {
  provider   = aws.relay
  key_name   = "v2ray-vpn-keypair"
  public_key = tls_private_key.v2ray_vpn_key.public_key_openssh

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group" "relay_sg" {
  provider    = aws.relay
  name        = "v2ray-relay-sg"
  description = "Allow HTTPS, HTTP (certbot), and SSH for relay node"

  ingress {
    description = "SSH from trusted IP"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["${var.trusted_ip}/32"]
  }

  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTP for Certbot ACME challenge"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_eip" "relay_eip" {
  provider = aws.relay
  domain   = "vpc"
}

resource "aws_instance" "relay" {
  provider                    = aws.relay
  ami                         = var.ami_relay
  instance_type               = "t3.nano"
  key_name                    = aws_key_pair.relay_key.key_name
  associate_public_ip_address = false
  vpc_security_group_ids      = [aws_security_group.relay_sg.id]

  tags = {
    Name = "v2ray-relay"
  }
}

resource "aws_eip_association" "relay_eip_assoc" {
  provider      = aws.relay
  instance_id   = aws_instance.relay.id
  allocation_id = aws_eip.relay_eip.id
}

# ---------------------------------------------------------------------------
# Exit node (internet egress)
# ---------------------------------------------------------------------------

resource "aws_key_pair" "exit_key" {
  provider   = aws.exit
  key_name   = "v2ray-vpn-keypair-exit"
  public_key = tls_private_key.v2ray_vpn_key.public_key_openssh
}

resource "aws_security_group" "exit_sg" {
  provider    = aws.exit
  name        = "v2ray-exit-sg"
  description = "Allow V2Ray traffic from relay node and SSH"

  ingress {
    description = "SSH from trusted IP"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["${var.trusted_ip}/32"]
  }

  ingress {
    description = "V2Ray traffic from relay node only"
    from_port   = 10000
    to_port     = 10000
    protocol    = "tcp"
    cidr_blocks = ["${aws_eip.relay_eip.public_ip}/32"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_eip" "exit_eip" {
  provider = aws.exit
  domain   = "vpc"
}

resource "aws_instance" "exit" {
  provider                    = aws.exit
  ami                         = var.ami_exit
  instance_type               = "t3.nano"
  key_name                    = aws_key_pair.exit_key.key_name
  associate_public_ip_address = false
  vpc_security_group_ids      = [aws_security_group.exit_sg.id]

  tags = {
    Name = "v2ray-exit"
  }
}

resource "aws_eip_association" "exit_eip_assoc" {
  provider      = aws.exit
  instance_id   = aws_instance.exit.id
  allocation_id = aws_eip.exit_eip.id
}

# ---------------------------------------------------------------------------
# Provision exit node first (it has no upstream dependency)
# ---------------------------------------------------------------------------

resource "null_resource" "provision_exit" {
  depends_on = [aws_eip_association.exit_eip_assoc]

  provisioner "file" {
    source      = "${path.module}/../.env"
    destination = "/home/ubuntu/.env"

    connection {
      type        = "ssh"
      user        = "ubuntu"
      private_key = tls_private_key.v2ray_vpn_key.private_key_pem
      host        = aws_eip.exit_eip.public_ip
    }
  }

  provisioner "file" {
    source      = "${path.module}/../server/scripts/setup-exit.sh"
    destination = "/home/ubuntu/setup-exit.sh"

    connection {
      type        = "ssh"
      user        = "ubuntu"
      private_key = tls_private_key.v2ray_vpn_key.private_key_pem
      host        = aws_eip.exit_eip.public_ip
    }
  }

  provisioner "remote-exec" {
    inline = [
      "sudo apt update -y",
      "sudo apt install -y docker.io docker-compose jq",
      "sudo systemctl enable docker",
      "sudo systemctl start docker",
      "chmod +x /home/ubuntu/setup-exit.sh",
      "sudo /home/ubuntu/setup-exit.sh"
    ]

    connection {
      type        = "ssh"
      user        = "ubuntu"
      private_key = tls_private_key.v2ray_vpn_key.private_key_pem
      host        = aws_eip.exit_eip.public_ip
    }
  }
}

# ---------------------------------------------------------------------------
# Provision relay node (needs exit node IP)
# ---------------------------------------------------------------------------

resource "null_resource" "provision_relay" {
  depends_on = [
    aws_eip_association.relay_eip_assoc,
    aws_eip_association.exit_eip_assoc
  ]

  provisioner "file" {
    source      = "${path.module}/../server/scripts/setup-relay.sh"
    destination = "/home/ubuntu/setup-relay.sh"

    connection {
      type        = "ssh"
      user        = "ubuntu"
      private_key = tls_private_key.v2ray_vpn_key.private_key_pem
      host        = aws_eip.relay_eip.public_ip
    }
  }

  provisioner "file" {
    source      = "${path.module}/../.env"
    destination = "/home/ubuntu/.env"

    connection {
      type        = "ssh"
      user        = "ubuntu"
      private_key = tls_private_key.v2ray_vpn_key.private_key_pem
      host        = aws_eip.relay_eip.public_ip
    }
  }

  provisioner "remote-exec" {
    inline = [
      "sudo apt update -y",
      "sudo apt install -y docker.io docker-compose jq",
      "sudo systemctl enable docker",
      "sudo systemctl start docker",
      "chmod +x /home/ubuntu/setup-relay.sh",
      format("sudo EXIT_NODE_IP=%s /home/ubuntu/setup-relay.sh", aws_eip.exit_eip.public_ip)
    ]

    connection {
      type        = "ssh"
      user        = "ubuntu"
      private_key = tls_private_key.v2ray_vpn_key.private_key_pem
      host        = aws_eip.relay_eip.public_ip
    }
  }

  provisioner "local-exec" {
    command = <<-EOT
      echo "Waiting for relay to finish provisioning..."
      sleep 40
      scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -i "${path.module}/v2ray-vpn-keypair.pem" \
        ubuntu@${aws_eip.relay_eip.public_ip}:/opt/v2ray/client-config.json \
        "${path.module}/client-config.json"
      echo "Client config downloaded to terraform/client-config.json"
    EOT
  }
}

# ---------------------------------------------------------------------------
# Outputs
# ---------------------------------------------------------------------------

output "relay_ip" {
  description = "Public IP of the relay node"
  value       = aws_eip.relay_eip.public_ip
}

output "exit_ip" {
  description = "Public IP of the exit node"
  value       = aws_eip.exit_eip.public_ip
}

output "private_key" {
  description = "SSH private key (use: terraform output -raw private_key > key.pem)"
  value       = tls_private_key.v2ray_vpn_key.private_key_pem
  sensitive   = true
}
