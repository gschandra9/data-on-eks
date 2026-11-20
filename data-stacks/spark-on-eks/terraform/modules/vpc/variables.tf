variable "mode" {
  description = "\"create\": Terraform creates the VPC. \"existing\": look up a VPC and subnets that already exist."
  type        = string
}

variable "name" {
  description = "Name prefix for resources created in create mode"
  type        = string
}

#---------------------------------------------------------------
# create mode
#---------------------------------------------------------------
variable "azs" {
  description = "Availability zones for the created VPC"
  type        = list(string)
}

variable "vpc_cidr" {
  description = "Primary IPv4 CIDR of the created VPC"
  type        = string
}

variable "secondary_cidrs" {
  description = "Secondary IPv4 CIDRs associated with the created VPC"
  type        = list(string)
}

variable "public_subnet_cidrs" {
  description = "Public subnet CIDRs, one per AZ. Empty: cidrsubnet(vpc_cidr, 8, 48 + az_index)."
  type        = list(string)
}

variable "private_subnet_cidrs" {
  description = "Private subnet CIDRs, one per AZ. Empty: cidrsubnet(vpc_cidr, 4, az_index)."
  type        = list(string)
}

variable "node_subnet_cidrs" {
  description = "Node subnet CIDRs, one per AZ. Empty: secondary_cidrs, one per AZ."
  type        = list(string)
}

variable "vpc_ipv6" {
  description = "Assign an Amazon-provided IPv6 /56 to the created VPC and its subnets"
  type        = bool
}

variable "single_nat_gateway" {
  description = "One NAT gateway for all AZs (true) or one per AZ (false)"
  type        = bool
}

variable "public_subnet_tags" {
  type = map(string)
}

variable "private_subnet_tags" {
  type = map(string)
}

#---------------------------------------------------------------
# existing mode
#---------------------------------------------------------------
variable "vpc_id" {
  description = "Existing VPC ID. If empty, vpc_name is used."
  type        = string
}

variable "vpc_name" {
  description = "Name tag of the existing VPC (used when vpc_id is empty)"
  type        = string
}

variable "public_subnet_ids" {
  type = list(string)
}

variable "private_subnet_ids" {
  type = list(string)
}

variable "node_subnet_ids" {
  type = list(string)
}
