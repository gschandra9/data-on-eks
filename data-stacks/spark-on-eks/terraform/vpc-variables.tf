# VPC variables for this stack. deploy.sh sets them as TF_VAR_* from
# --vpc-mode and --vpc-config. Do not set them in data-stack.tfvars:
# -var-file values override TF_VAR_* environment variables.
# vpc_cidr, secondary_cidrs, public_subnet_tags and private_subnet_tags
# are declared in infra/terraform/variables.tf.

variable "vpc_mode" {
  description = "\"create\": Terraform creates the VPC. \"existing\": deploy into an existing VPC."
  type        = string
  default     = "create"

  validation {
    condition     = contains(["create", "existing"], var.vpc_mode)
    error_message = "vpc_mode must be \"create\" or \"existing\"."
  }
}

# Set by deploy.sh after checking the VPC for existing endpoints (create_vpc_endpoints in --vpc-config).
# null (Terraform run without deploy.sh): create in create mode, skip in existing mode.
variable "create_s3_endpoint" {
  description = "Create the S3 interface VPC endpoint"
  type        = bool
  default     = null
}

variable "create_s3express_endpoint" {
  description = "Create the S3 Express gateway VPC endpoint"
  type        = bool
  default     = null
}

# Set by deploy.sh (existing mode, create_interface_endpoints in --vpc-config): interface endpoint
# services to create so nodes without a NAT route can reach AWS APIs. Names are service suffixes,
# e.g. "ec2", "ecr.api". Empty: create none.
variable "create_interface_endpoints" {
  description = "Interface VPC endpoint services to create in the node subnets (empty: none)"
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for s in var.create_interface_endpoints : contains(["ec2", "ecr.api", "ecr.dkr", "sts", "eks", "eks-auth", "logs", "sqs", "ssm", "elasticloadbalancing"], s)])
    error_message = "Supported services: ec2, ecr.api, ecr.dkr, sts, eks, eks-auth, logs, sqs, ssm, elasticloadbalancing."
  }
}

# Set by deploy.sh (existing mode, update_s3_endpoint_policy in --vpc-config): IDs of the VPC's
# existing S3 endpoints whose policy gets a statement allowing the ECR image-layer bucket.
variable "s3_endpoint_policy_ids" {
  description = "Existing S3 VPC endpoint IDs to extend with an ECR image-layer bucket statement (empty: none)"
  type        = list(string)
  default     = []
}

#---------------------------------------------------------------
# create mode
#---------------------------------------------------------------
variable "az_count" {
  description = "Number of AZs for the created VPC (first N AZs of the region)"
  type        = number
  default     = 3
}

variable "public_subnet_cidrs" {
  description = "Public subnet CIDRs, one per AZ. Empty: derived from vpc_cidr."
  type        = list(string)
  default     = []

  validation {
    condition     = length(var.public_subnet_cidrs) == 0 || length(var.public_subnet_cidrs) == var.az_count
    error_message = "public_subnet_cidrs must be empty or have one CIDR per AZ (az_count)."
  }
}

variable "private_subnet_cidrs" {
  description = "Private subnet CIDRs, one per AZ. Empty: derived from vpc_cidr."
  type        = list(string)
  default     = []

  validation {
    condition     = length(var.private_subnet_cidrs) == 0 || length(var.private_subnet_cidrs) == var.az_count
    error_message = "private_subnet_cidrs must be empty or have one CIDR per AZ (az_count)."
  }
}

variable "node_subnet_cidrs" {
  description = "Node subnet CIDRs (EKS ENIs, nodes, Karpenter), one per AZ. Empty: secondary_cidrs."
  type        = list(string)
  default     = []

  validation {
    condition     = var.vpc_mode != "create" || (length(var.node_subnet_cidrs) == 0 ? length(var.secondary_cidrs) >= var.az_count : length(var.node_subnet_cidrs) == var.az_count)
    error_message = "Create mode needs one node subnet per AZ: set node_subnet_cidrs (az_count entries) or at least az_count secondary_cidrs."
  }
}

variable "vpc_ipv6" {
  description = "Assign an Amazon-provided IPv6 /56 to the created VPC"
  type        = bool
  default     = true
}

variable "single_nat_gateway" {
  description = "One NAT gateway for all AZs (true) or one per AZ (false)"
  type        = bool
  default     = true
}

#---------------------------------------------------------------
# existing mode
#---------------------------------------------------------------
variable "vpc_id" {
  description = "ID of the existing VPC. If empty, vpc_name is used."
  type        = string
  default     = ""
}

variable "vpc_name" {
  description = "Name tag of the existing VPC (used when vpc_id is empty)"
  type        = string
  default     = ""

  validation {
    condition     = var.vpc_mode != "existing" || var.vpc_id != "" || var.vpc_name != ""
    error_message = "Existing mode needs vpc_id or vpc_name."
  }
}

variable "public_subnet_ids" {
  description = "Existing public subnet IDs (optional)"
  type        = list(string)
  default     = []
}

variable "private_subnet_ids" {
  description = "Existing private subnet IDs (one per AZ)"
  type        = list(string)
  default     = []

  validation {
    condition     = var.vpc_mode != "existing" || length(var.private_subnet_ids) > 0
    error_message = "Existing mode needs private_subnet_ids."
  }
}

variable "node_subnet_ids" {
  description = "Existing subnet IDs for the EKS control plane ENIs, core node group and Karpenter nodes"
  type        = list(string)
  default     = []

  validation {
    condition     = var.vpc_mode != "existing" || length(var.node_subnet_ids) >= 2
    error_message = "Existing mode needs at least 2 node_subnet_ids in different AZs (EKS requirement)."
  }
}
