# Overrides infra/terraform/vpc.tf for this stack.
# VPC settings come from deploy.sh (--vpc-mode / --vpc-config) as TF_VAR_* variables.

data "aws_availability_zones" "available" {}

locals {
  azs             = module.vpc.azs
  node_subnet_ids = module.vpc.node_subnets

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

module "vpc_endpoints" {
  count  = local.create_s3_endpoint || local.create_s3express_endpoint ? 1 : 0
  source = "terraform-aws-modules/vpc/aws//modules/vpc-endpoints"

  vpc_id = module.vpc.vpc_id

  # Keep only the endpoints that should be created
  endpoints = { for k, v in local.vpc_endpoints : k => v if local.vpc_endpoint_enabled[k] }

  # deploy.sh relies on this Name tag to tell this deployment's endpoints from pre-existing ones
  tags = {
    Name = "${var.name}-vpc-endpoints"
  }
}

locals {
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
