variable "name" {
  description = "Prefix for resources and secret paths (<name>/<KEY>)."
  type        = string
  default     = "litellm"
}

variable "region" {
  description = "AWS region for the instance and the default Bedrock region."
  type        = string
  default     = "ap-south-1"
}

variable "tags" {
  type    = map(string)
  default = {}
}

# ---------- Network ----------
variable "vpc_id" {
  description = "VPC to deploy into. Empty = the account's default VPC."
  type        = string
  default     = ""
}

variable "subnet_id" {
  description = "Subnet for the instance (needs outbound internet: public subnet or NAT). Empty = first subnet of the VPC."
  type        = string
  default     = ""
}

variable "alb_subnet_ids" {
  description = "At least two subnets in different AZs for the ALB. Empty = all subnets of the VPC."
  type        = list(string)
  default     = []
}

variable "associate_public_ip" {
  description = "Attach an Elastic IP. Needed when the instance sits in a public subnet without NAT."
  type        = bool
  default     = true
}

variable "allowed_cidrs" {
  description = "CIDRs allowed to reach the gateway (office / VPN egress). Avoid 0.0.0.0/0."
  type        = list(string)
}

variable "acm_certificate_arn" {
  description = "ACM certificate ARN. Set it to put an HTTPS ALB in front; empty = direct HTTP on :4000 (testing only)."
  type        = string
  default     = ""
}

# ---------- Instance ----------
variable "instance_type" {
  description = "Runs LiteLLM + Postgres + Redis. t3.large (2 vCPU / 8 GiB) suits a team gateway."
  type        = string
  default     = "t3.large"
}

variable "root_volume_gb" {
  type    = number
  default = 40
}

variable "swap_gb" {
  description = "Swap file size on the host. Needed on 2 GiB instances (t4g.small / t3.small); 0 disables."
  type        = number
  default     = 2
}

variable "cpu_credits" {
  description = "Burstable (t-family) credit mode: standard (no surprise charges, throttles) or unlimited."
  type        = string
  default     = "standard"

  validation {
    condition     = contains(["standard", "unlimited"], var.cpu_credits)
    error_message = "cpu_credits must be \"standard\" or \"unlimited\"."
  }
}

variable "litellm_tag" {
  description = "Exact LiteLLM image tag (v1.83.0 or later). Never 'latest'."
  type        = string
}

variable "compose_version" {
  description = "Docker Compose plugin release installed on the host."
  type        = string
  default     = "v2.29.7"
}

variable "snapshot_retention_days" {
  description = "Daily EBS snapshots (Postgres data lives on the root volume)."
  type        = number
  default     = 7
}

variable "log_retention_days" {
  type    = number
  default = 30
}

# ---------- Providers ----------
variable "bedrock_region" {
  description = "Region LiteLLM calls Bedrock in. Empty = same as region."
  type        = string
  default     = ""
}

variable "azure_api_base" {
  type    = string
  default = ""
}

variable "azure_api_version" {
  type    = string
  default = "2024-10-21"
}

variable "provider_secret_names" {
  description = "External provider keys. Created as REPLACE_ME secrets; fill with set-secret.sh. Bedrock needs none."
  type        = list(string)
  default     = ["ANTHROPIC_API_KEY", "OPENAI_API_KEY", "AZURE_API_KEY", "GEMINI_API_KEY", "GROQ_API_KEY", "COHERE_API_KEY"]
}

# ---------- Cost alert ----------
variable "monthly_budget_usd" {
  description = "Monthly AWS cost budget for the account; alerts at 80% actual and 100% forecast."
  type        = number
  default     = 25
}

variable "budget_alert_email" {
  description = "Email for budget alerts. Empty = no budget."
  type        = string
  default     = ""
}
