variable "trusted_ip" {
  description = "Your public IP for SSH access (run: curl -s ifconfig.me)"
  type        = string

  validation {
    condition     = can(cidrhost("${var.trusted_ip}/32", 0))
    error_message = "trusted_ip must be a valid IPv4 address."
  }
}

variable "ami_relay" {
  description = "AMI ID for the relay region (Ubuntu 22.04)"
  type        = string
}

variable "ami_exit" {
  description = "AMI ID for the exit region (Ubuntu 22.04)"
  type        = string
}

variable "relay_region" {
  description = "AWS region for the relay node"
  type        = string
  default     = "ap-northeast-1"
}

variable "exit_region" {
  description = "AWS region for the exit node"
  type        = string
  default     = "us-east-1"
}
