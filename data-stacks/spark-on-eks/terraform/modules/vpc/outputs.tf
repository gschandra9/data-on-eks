# try() keeps the branch for the inactive mode from failing on an empty count index.

output "vpc_id" {
  value = local.create ? try(module.this[0].vpc_id, null) : try(data.aws_vpc.existing[0].id, null)
}

# All IPv4 CIDRs of the VPC (primary + secondary)
output "vpc_cidr_blocks" {
  value = local.create ? try(concat([module.this[0].vpc_cidr_block], module.this[0].vpc_secondary_cidr_blocks), []) : try(
    [for a in data.aws_vpc.existing[0].cidr_block_associations : a.cidr_block], []
  )
}

output "vpc_ipv6_cidr_block" {
  value = local.create ? (var.vpc_ipv6 ? try(module.this[0].vpc_ipv6_cidr_block, null) : null) : try(
    one(data.aws_vpc.existing[0].ipv6_cidr_block_associations[*].ipv6_cidr_block), null
  )
}

# Known at plan time in both modes (safe for count / dynamic blocks)
output "has_ipv6" {
  value = local.create ? var.vpc_ipv6 : try(length(data.aws_vpc.existing[0].ipv6_cidr_block_associations) > 0, false)
}

output "azs" {
  value = local.create ? var.azs : distinct([for id in var.node_subnet_ids : data.aws_subnet.existing[id].availability_zone])
}

output "public_subnets" {
  value = local.create ? try(module.this[0].public_subnets, []) : var.public_subnet_ids
}

# Primary private subnets (one per AZ)
output "private_subnets" {
  value = local.create ? try(slice(module.this[0].private_subnets, 0, local.n_azs), []) : var.private_subnet_ids
}

# Subnets for the EKS control plane ENIs, core node group and Karpenter nodes
output "node_subnets" {
  value = local.create ? try(slice(module.this[0].private_subnets, local.n_azs, local.n_azs * 2), []) : var.node_subnet_ids
}

output "private_route_table_ids" {
  value = local.create ? try(module.this[0].private_route_table_ids, []) : try(data.aws_route_tables.private[0].ids, [])
}

output "public_route_table_ids" {
  value = local.create ? try(module.this[0].public_route_table_ids, []) : try(data.aws_route_tables.public[0].ids, [])
}
