data "aws_caller_identity" "current" {}

# ---------- Network lookup ----------
data "aws_vpc" "selected" {
  id      = var.vpc_id != "" ? var.vpc_id : null
  default = var.vpc_id == "" ? true : null
}

data "aws_subnets" "vpc" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.selected.id]
  }
}

locals {
  subnet_id      = var.subnet_id != "" ? var.subnet_id : sort(data.aws_subnets.vpc.ids)[0]
  alb_subnet_ids = length(var.alb_subnet_ids) > 0 ? var.alb_subnet_ids : data.aws_subnets.vpc.ids
  https_enabled  = var.acm_certificate_arn != ""
  caddy_enabled  = var.public_https && !local.https_enabled && var.associate_public_ip
  bedrock_region = var.bedrock_region != "" ? var.bedrock_region : var.region
  log_group_name = "/litellm/${var.name}"
}

# ---------- Security group ----------
resource "aws_security_group" "instance" {
  name        = "${var.name}-instance"
  description = "LiteLLM host"
  vpc_id      = data.aws_vpc.selected.id

  egress {
    description = "Provider APIs, Bedrock, Secrets Manager, S3, image registries"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Without an ALB: allowed CIDRs hit :4000 directly (testing only, plain HTTP).
resource "aws_vpc_security_group_ingress_rule" "direct" {
  for_each          = local.https_enabled ? toset([]) : toset(var.allowed_cidrs)
  security_group_id = aws_security_group.instance.id
  description       = "LiteLLM direct"
  cidr_ipv4         = each.value
  from_port         = 4000
  to_port           = 4000
  ip_protocol       = "tcp"
}

# Caddy on the instance: 443 for HTTPS, 80 for the Let's Encrypt HTTP challenge (and redirect).
resource "aws_vpc_security_group_ingress_rule" "public_https" {
  for_each          = local.caddy_enabled ? { for pair in setproduct(var.public_cidrs, [80, 443]) : "${pair[0]}:${pair[1]}" => pair } : {}
  security_group_id = aws_security_group.instance.id
  description       = "Caddy ${each.value[1]}"
  cidr_ipv4         = each.value[0]
  from_port         = each.value[1]
  to_port           = each.value[1]
  ip_protocol       = "tcp"
}

# With an ALB: only the ALB reaches :4000.
resource "aws_vpc_security_group_ingress_rule" "from_alb" {
  count                        = local.https_enabled ? 1 : 0
  security_group_id            = aws_security_group.instance.id
  description                  = "LiteLLM from ALB"
  referenced_security_group_id = aws_security_group.alb[0].id
  from_port                    = 4000
  to_port                      = 4000
  ip_protocol                  = "tcp"
}

# ---------- Secrets ----------
resource "random_password" "master_key" {
  length  = 48
  special = false
}

# Encrypts provider keys stored in the DB. Never rotate once models/keys are in the DB.
resource "random_password" "salt_key" {
  length  = 48
  special = false
}

resource "random_password" "postgres" {
  length  = 32
  special = false
}

locals {
  generated_secrets = {
    LITELLM_MASTER_KEY = "sk-${random_password.master_key.result}"
    LITELLM_SALT_KEY   = "sk-${random_password.salt_key.result}"
    POSTGRES_PASSWORD  = random_password.postgres.result
  }
}

resource "aws_secretsmanager_secret" "generated" {
  for_each                = toset(["LITELLM_MASTER_KEY", "LITELLM_SALT_KEY", "POSTGRES_PASSWORD"])
  name                    = "${var.name}/${each.key}"
  recovery_window_in_days = 7
}

resource "aws_secretsmanager_secret_version" "generated" {
  for_each      = aws_secretsmanager_secret.generated
  secret_id     = each.value.id
  secret_string = local.generated_secrets[each.key]
}

resource "aws_secretsmanager_secret" "provider" {
  for_each                = toset(var.provider_secret_names)
  name                    = "${var.name}/${each.key}"
  recovery_window_in_days = 7
}

resource "aws_secretsmanager_secret_version" "provider" {
  for_each      = aws_secretsmanager_secret.provider
  secret_id     = each.value.id
  secret_string = "REPLACE_ME"

  # Real values are written with set-secret.sh and must never be overwritten by Terraform.
  lifecycle {
    ignore_changes = [secret_string, version_stages]
  }
}

# ---------- Config bundle (S3) ----------
resource "aws_s3_bucket" "bundle" {
  bucket_prefix = "${var.name}-bundle-"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "bundle" {
  bucket                  = aws_s3_bucket.bundle.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "bundle" {
  bucket = aws_s3_bucket.bundle.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_versioning" "bundle" {
  bucket = aws_s3_bucket.bundle.id
  versioning_configuration {
    status = "Enabled" # every config.yaml change is recoverable
  }
}

resource "aws_s3_object" "app" {
  for_each = fileset("${path.module}/../app", "**")
  bucket   = aws_s3_bucket.bundle.id
  key      = "app/${each.value}"
  source   = "${path.module}/../app/${each.value}"
  etag     = filemd5("${path.module}/../app/${each.value}")
}

resource "aws_s3_object" "launcher" {
  bucket = aws_s3_bucket.bundle.id
  key    = "bin/litellm-up"
  source = "${path.module}/../host/litellm-up"
  etag   = filemd5("${path.module}/../host/litellm-up")
}

# Non-secret runtime settings read by litellm-up.
resource "aws_s3_object" "bootstrap_env" {
  bucket = aws_s3_bucket.bundle.id
  key    = "app/bootstrap.env"
  content = join("\n", [
    "NAME=${var.name}",
    "SECRET_KEYS=\"LITELLM_MASTER_KEY LITELLM_SALT_KEY POSTGRES_PASSWORD ${join(" ", var.provider_secret_names)}\"",
    "LITELLM_TAG=${var.litellm_tag}",
    "AWS_REGION_NAME=${local.bedrock_region}",
    "AZURE_API_BASE=${var.azure_api_base}",
    "AZURE_API_VERSION=${var.azure_api_version}",
    "LOG_GROUP=${local.log_group_name}",
    "LOG_REGION=${var.region}",
    "PUBLIC_HTTPS=${local.caddy_enabled}",
    "PUBLIC_HOSTNAME=${var.public_hostname}",
    "",
  ])
}

# ---------- Logs ----------
resource "aws_cloudwatch_log_group" "litellm" {
  name              = local.log_group_name
  retention_in_days = var.log_retention_days
}

# ---------- IAM (instance role) ----------
data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "instance" {
  name               = "${var.name}-instance"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

# Shell access via SSM Session Manager — no SSH port, no key pair.
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "instance" {
  statement {
    sid = "Bedrock"
    actions = [
      "bedrock:InvokeModel",
      "bedrock:InvokeModelWithResponseStream",
    ]
    # Wildcard region: cross-region inference profiles route to other regions.
    resources = [
      "arn:aws:bedrock:*::foundation-model/*",
      "arn:aws:bedrock:*:${data.aws_caller_identity.current.account_id}:inference-profile/*",
      "arn:aws:bedrock:*:${data.aws_caller_identity.current.account_id}:application-inference-profile/*",
    ]
  }

  statement {
    sid = "BedrockDiscovery"
    actions = [
      "bedrock:ListFoundationModels",
      "bedrock:ListInferenceProfiles",
      "bedrock:GetInferenceProfile",
    ]
    resources = ["*"]
  }

  statement {
    sid     = "Secrets"
    actions = ["secretsmanager:GetSecretValue"]
    resources = concat(
      [for s in aws_secretsmanager_secret.generated : s.arn],
      [for s in aws_secretsmanager_secret.provider : s.arn]
    )
  }

  statement {
    sid       = "Bundle"
    actions   = ["s3:GetObject", "s3:ListBucket"]
    resources = [aws_s3_bucket.bundle.arn, "${aws_s3_bucket.bundle.arn}/*"]
  }

  statement {
    sid       = "Logs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"]
    resources = ["${aws_cloudwatch_log_group.litellm.arn}:*"]
  }
}

resource "aws_iam_role_policy" "instance" {
  name   = "litellm-runtime"
  role   = aws_iam_role.instance.id
  policy = data.aws_iam_policy_document.instance.json
}

resource "aws_iam_instance_profile" "instance" {
  name = "${var.name}-instance"
  role = aws_iam_role.instance.name
}

# ---------- EC2 ----------
# Pick the ARM (Graviton, e.g. t4g) or x86 AMI to match the instance type.
data "aws_ec2_instance_type" "this" {
  instance_type = var.instance_type
}

locals {
  arch      = contains(data.aws_ec2_instance_type.this.supported_architectures, "arm64") ? "arm64" : "x86_64"
  burstable = data.aws_ec2_instance_type.this.burstable_performance_supported
}

data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-${local.arch}"
}

resource "aws_instance" "litellm" {
  ami                    = data.aws_ssm_parameter.al2023.value
  instance_type          = var.instance_type
  subnet_id              = local.subnet_id
  vpc_security_group_ids = [aws_security_group.instance.id]
  iam_instance_profile   = aws_iam_instance_profile.instance.name

  # IMDSv2 only. Hop limit 2 lets the LiteLLM container reach the instance role (for Bedrock).
  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
    http_endpoint               = "enabled"
  }

  # t-family: "standard" never bills for extra CPU credits (the instance is throttled instead).
  dynamic "credit_specification" {
    for_each = local.burstable ? [1] : []
    content {
      cpu_credits = var.cpu_credits
    }
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = var.root_volume_gb
    encrypted   = true
    tags = {
      Name   = "${var.name}-root"
      Backup = var.name
    }
  }

  user_data = templatefile("${path.module}/../host/user-data.sh.tftpl", {
    bucket          = aws_s3_bucket.bundle.id
    region          = var.region
    compose_version = var.compose_version
    swap_gb         = var.swap_gb
  })

  tags = {
    Name = var.name
  }

  lifecycle {
    ignore_changes = [ami] # don't replace the host when a newer AMI is published
  }

  # Everything the first boot reads must exist before the instance starts.
  depends_on = [
    aws_s3_object.app,
    aws_s3_object.launcher,
    aws_s3_object.bootstrap_env,
    aws_secretsmanager_secret_version.generated,
    aws_secretsmanager_secret_version.provider,
    aws_iam_role_policy.instance,
  ]
}

resource "aws_eip" "litellm" {
  count    = var.associate_public_ip ? 1 : 0
  domain   = "vpc"
  instance = aws_instance.litellm.id
}

# ---------- Daily EBS snapshots (Postgres lives on the root volume) ----------
data "aws_iam_policy_document" "dlm_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["dlm.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "dlm" {
  name               = "${var.name}-dlm"
  assume_role_policy = data.aws_iam_policy_document.dlm_assume.json
}

resource "aws_iam_role_policy_attachment" "dlm" {
  role       = aws_iam_role.dlm.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSDataLifecycleManagerServiceRole"
}

resource "aws_dlm_lifecycle_policy" "snapshots" {
  description        = "${var.name} daily root volume snapshots"
  execution_role_arn = aws_iam_role.dlm.arn
  state              = "ENABLED"

  policy_details {
    resource_types = ["VOLUME"]
    target_tags = {
      Backup = var.name
    }

    schedule {
      name = "daily"
      create_rule {
        interval      = 24
        interval_unit = "HOURS"
        times         = ["20:30"] # UTC = 02:00 IST
      }
      retain_rule {
        count = var.snapshot_retention_days
      }
      copy_tags = true
    }
  }
}
