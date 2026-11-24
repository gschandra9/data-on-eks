# Overrides infra/terraform/vpc.tf for this stack.
# VPC settings come from deploy.sh (--vpc-mode / --vpc-config) as TF_VAR_* variables.

data "aws_availability_zones" "available" {}

locals {
  azs = module.vpc.azs

  # Existing VPC: its subnets don't carry the kubernetes.io/role/internal-elb tag (and are not
  # modified), so internal load balancers (ingress-nginx NLB) get the private subnet IDs directly.
  # Created VPC: the subnets are tagged, the controller discovers them.
  internal_lb_subnet_ids = var.vpc_mode == "existing" ? module.vpc.private_subnets : []
  # The filter condition is always true. It makes module.eks (core node group) and Karpenter
  # wait for module.vpc_endpoints, so the endpoints exist before the first node boots
  # (install.sh applies -target=module.eks before the final full apply).
  node_subnet_ids = [
    for s in module.vpc.node_subnets : s
    if length(module.vpc_endpoints) >= 0 && length(aws_vpc_endpoint_policy.ecr_layers) >= 0
  ]

  # S3 endpoints: deploy.sh decides per endpoint (missing in the VPC -> create).
  # Without deploy.sh: create in create mode, skip in existing mode.
  create_s3_endpoint        = var.create_s3_endpoint != null ? var.create_s3_endpoint : var.vpc_mode == "create"
  create_s3express_endpoint = var.create_s3express_endpoint != null ? var.create_s3express_endpoint : var.vpc_mode == "create"
}

#---------------------------------------------------------------
# VPC (created or existing, see modules/vpc)
#---------------------------------------------------------------
module "vpc" {
  source = "./modules/vpc"

  mode = var.vpc_mode
  name = var.name

  # create mode
  azs                  = slice(data.aws_availability_zones.available.names, 0, var.az_count)
  vpc_cidr             = var.vpc_cidr
  secondary_cidrs      = var.secondary_cidrs
  public_subnet_cidrs  = var.public_subnet_cidrs
  private_subnet_cidrs = var.private_subnet_cidrs
  node_subnet_cidrs    = var.node_subnet_cidrs
  vpc_ipv6             = var.vpc_ipv6
  single_nat_gateway   = var.single_nat_gateway
  public_subnet_tags   = var.public_subnet_tags
  private_subnet_tags  = var.private_subnet_tags

  # existing mode
  vpc_id             = var.vpc_id
  vpc_name           = var.vpc_name
  public_subnet_ids  = var.public_subnet_ids
  private_subnet_ids = var.private_subnet_ids
  node_subnet_ids    = var.node_subnet_ids
}

#---------------------------------------------------------------
# VPC Endpoints
#---------------------------------------------------------------

# ECR serves image layers from an AWS-owned S3 bucket. An existing S3 endpoint whose policy only
# allows other buckets answers 403 and the CNI/kube-proxy images can't be pulled. Keep the
# endpoint's current statements and add one for the layer bucket (idempotent: replaced by Sid).
# Destroying this resource resets the endpoint policy to the AWS default (full access).
data "aws_vpc_endpoint" "existing_s3" {
  for_each = toset(var.s3_endpoint_policy_ids)
  id       = each.value
}

locals {
  ecr_layers_statement = {
    Sid       = "AllowEcrImageLayers"
    Effect    = "Allow"
    Principal = "*"
    Action    = "s3:GetObject"
    Resource  = "arn:aws:s3:::prod-${var.region}-starport-layer-bucket/*"
  }
}

resource "aws_vpc_endpoint_policy" "ecr_layers" {
  for_each        = toset(var.s3_endpoint_policy_ids)
  vpc_endpoint_id = each.value

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [for st in flatten([jsondecode(data.aws_vpc_endpoint.existing_s3[each.value].policy).Statement]) : st if try(st.Sid, "") != local.ecr_layers_statement.Sid],
      [local.ecr_layers_statement]
    )
  })
}

resource "aws_security_group" "vpc_endpoint_s3" {
  count = local.create_s3_endpoint ? 1 : 0

  name_prefix = "${var.name}-vpc-endpoint-s3"
  vpc_id      = module.vpc.vpc_id

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = module.vpc.vpc_cidr_blocks
  }

  dynamic "ingress" {
    for_each = module.vpc.has_ipv6 ? [module.vpc.vpc_ipv6_cidr_block] : []
    content {
      from_port        = 443
      to_port          = 443
      protocol         = "tcp"
      ipv6_cidr_blocks = [ingress.value]
    }
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  dynamic "egress" {
    for_each = module.vpc.has_ipv6 ? [1] : []
    content {
      from_port        = 0
      to_port          = 0
      protocol         = "-1"
      ipv6_cidr_blocks = ["::/0"]
    }
  }

  tags = {
    Name = "${var.name}-vpc-endpoint-s3"
  }
}

# Interface endpoints for AWS APIs the nodes need to join the cluster and run add-ons
# (only when deploy.sh found them missing in an existing VPC without NAT access).
resource "aws_security_group" "vpc_endpoint_interface" {
  count = length(var.create_interface_endpoints) > 0 ? 1 : 0

  name_prefix = "${var.name}-vpc-endpoint-api"
  description = "HTTPS from the VPC to interface VPC endpoints"
  vpc_id      = module.vpc.vpc_id

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = module.vpc.vpc_cidr_blocks
  }

  tags = {
    Name = "${var.name}-vpc-endpoint-api"
  }
}

module "vpc_endpoints" {
  count  = local.create_s3_endpoint || local.create_s3express_endpoint || length(var.create_interface_endpoints) > 0 ? 1 : 0
  source = "terraform-aws-modules/vpc/aws//modules/vpc-endpoints"

  vpc_id = module.vpc.vpc_id

  # Keep only the endpoints that should be created
  endpoints = merge(
    { for k, v in local.vpc_endpoints : k => v if local.vpc_endpoint_enabled[k] },
    local.interface_endpoints
  )

  # deploy.sh / cleanup.sh use this tag to tell this deployment's endpoints from pre-existing ones.
  # (The module overwrites the Name tag with the endpoint key, so Name can't be used for this.)
  tags = {
    "data-on-eks:deployment" = var.name
  }
}

locals {
  # One interface endpoint per requested service, in the node subnets (the AZs where nodes run)
  interface_endpoints = {
    for s in var.create_interface_endpoints : replace(s, ".", "_") => {
      service             = s
      subnet_ids          = module.vpc.node_subnets
      security_group_ids  = [aws_security_group.vpc_endpoint_interface[0].id]
      private_dns_enabled = true
      # No per-endpoint tags: the module-level "data-on-eks:deployment" tag marks these endpoints.
    }
  }

  vpc_endpoint_enabled = {
    s3        = local.create_s3_endpoint
    s3express = local.create_s3express_endpoint
  }

  vpc_endpoints = {
    s3 = {
      service            = "s3"
      subnet_ids         = module.vpc.private_subnets
      security_group_ids = try([aws_security_group.vpc_endpoint_s3[0].id], [])
      route_table_ids = concat(
        module.vpc.private_route_table_ids,
        module.vpc.public_route_table_ids
      )
      ip_address_type = module.vpc.has_ipv6 ? "dualstack" : "ipv4"
      dns_options = {
        dns_record_ip_type = module.vpc.has_ipv6 && var.enable_ipv6 ? "dualstack" : "ipv4"
      }
      private_dns_enabled = true
    }
    s3express = {
      service      = "s3express"
      service_type = "Gateway"
      route_table_ids = concat(
        module.vpc.private_route_table_ids
      )
    }
  }
}
