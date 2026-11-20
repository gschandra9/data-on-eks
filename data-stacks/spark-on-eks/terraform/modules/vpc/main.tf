# One "module.vpc" for both modes, so install.sh's `-target=module.vpc` and every
# module.vpc.* reference in the stack work unchanged.
#   create   -> terraform-aws-modules/vpc creates the VPC, subnets, NAT, IGW
#   existing -> data sources only; nothing in the VPC is created or modified

locals {
  create   = var.mode == "create"
  existing = var.mode == "existing"
  n_azs    = length(var.azs)

  # create mode layout: explicit CIDRs win, otherwise derived from vpc_cidr / secondary_cidrs
  public_cidrs = length(var.public_subnet_cidrs) > 0 ? var.public_subnet_cidrs : [
    for k, _ in var.azs : cidrsubnet(var.vpc_cidr, 8, k + 48)
  ]
  private_cidrs = length(var.private_subnet_cidrs) > 0 ? var.private_subnet_cidrs : [
    for k, _ in var.azs : cidrsubnet(var.vpc_cidr, 4, k)
  ]
  node_cidrs = length(var.node_subnet_cidrs) > 0 ? var.node_subnet_cidrs : (
    local.create ? slice(var.secondary_cidrs, 0, local.n_azs) : []
  )
}

#---------------------------------------------------------------
# create mode
#---------------------------------------------------------------
module "this" {
  count   = local.create ? 1 : 0
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.0"

  name = var.name
  cidr = var.vpc_cidr
  azs  = var.azs

  secondary_cidr_blocks = var.secondary_cidrs

  # Order matters: primary private subnets first, node subnets second (see outputs.tf)
  private_subnets = concat(local.private_cidrs, local.node_cidrs)
  public_subnets  = local.public_cidrs

  private_subnet_names = concat(
    [for az in var.azs : "${var.name}-private-${az}"],
    [for az in var.azs : "${var.name}-private-secondary1-${az}"]
  )
  public_subnet_names = [for az in var.azs : "${var.name}-public-${az}"]

  enable_nat_gateway = true
  single_nat_gateway = var.single_nat_gateway

  enable_ipv6                                    = var.vpc_ipv6
  create_egress_only_igw                         = var.vpc_ipv6
  public_subnet_ipv6_prefixes                    = var.vpc_ipv6 ? [for k, _ in var.azs : k] : []
  private_subnet_ipv6_prefixes                   = var.vpc_ipv6 ? [for i in range(local.n_azs * 2) : i + local.n_azs] : []
  public_subnet_assign_ipv6_address_on_creation  = var.vpc_ipv6
  private_subnet_assign_ipv6_address_on_creation = var.vpc_ipv6

  public_subnet_tags = merge(var.public_subnet_tags, {
    "kubernetes.io/role/elb" = 1
  })
  private_subnet_tags = merge(var.private_subnet_tags, {
    "kubernetes.io/role/internal-elb" = 1
    "karpenter.sh/discovery"          = var.name
  })
}

#---------------------------------------------------------------
# existing mode
#---------------------------------------------------------------
data "aws_vpc" "existing" {
  count = local.existing ? 1 : 0

  id   = var.vpc_id != "" ? var.vpc_id : null
  tags = var.vpc_id == "" ? { Name = var.vpc_name } : null
}

data "aws_subnet" "existing" {
  for_each = local.existing ? toset(concat(var.public_subnet_ids, var.private_subnet_ids, var.node_subnet_ids)) : toset([])
  id       = each.value

  lifecycle {
    postcondition {
      condition     = self.vpc_id == data.aws_vpc.existing[0].id
      error_message = "Subnet ${self.id} is in ${self.vpc_id}, not in the selected VPC ${data.aws_vpc.existing[0].id}."
    }
  }
}

# Route tables explicitly associated with the subnets (used only for VPC endpoints)
data "aws_route_tables" "private" {
  count  = local.existing ? 1 : 0
  vpc_id = data.aws_vpc.existing[0].id

  filter {
    name   = "association.subnet-id"
    values = concat(var.private_subnet_ids, var.node_subnet_ids)
  }
}

data "aws_route_tables" "public" {
  count  = local.existing && length(var.public_subnet_ids) > 0 ? 1 : 0
  vpc_id = data.aws_vpc.existing[0].id

  filter {
    name   = "association.subnet-id"
    values = var.public_subnet_ids
  }
}
