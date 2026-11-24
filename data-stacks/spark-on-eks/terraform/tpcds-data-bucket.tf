#---------------------------------------------------------------
# S3 bucket for Spark TPC-DS benchmark data (this stack only)
#
# Name: <prefix>spark-benchmarks-tpcds-data-<region>-<account id>
#   <prefix> is the --prefix given to deploy.sh (var.name = <prefix>spark-on-eks), e.g.
#   fs-spark-benchmarks-tpcds-data-us-west-2-123456789012
#
# The bucket is meant for large datasets that are expensive to recreate, so unlike the other
# stack buckets it is NOT force-destroyed:
#   - cleanup.sh keeps it (removes it from the Terraform state only) when it contains objects,
#     unless you confirm deletion of the data; an empty bucket is deleted normally.
#   - deploy.sh sets tpcds_data_bucket_adopt=true when the bucket already exists in this account
#     but not in the state, and the import block below adopts it instead of failing.
#---------------------------------------------------------------
variable "tpcds_data_bucket_adopt" {
  description = "Set by deploy.sh: the TPC-DS data bucket already exists in this account (kept by an earlier cleanup) and is imported"
  type        = bool
  default     = false
}

variable "tpcds_data_bucket_force_destroy" {
  description = "Allow terraform destroy to delete the TPC-DS data bucket even when it contains objects"
  type        = bool
  default     = false
}

locals {
  name_prefix       = trimsuffix(var.name, "spark-on-eks")
  tpcds_data_bucket = "${local.name_prefix}spark-benchmarks-tpcds-data-${var.region}-${local.account_id}"
}

import {
  for_each = var.tpcds_data_bucket_adopt ? toset([local.tpcds_data_bucket]) : toset([])
  to       = aws_s3_bucket.tpcds_data
  id       = each.value
}

resource "aws_s3_bucket" "tpcds_data" {
  bucket        = local.tpcds_data_bucket
  force_destroy = var.tpcds_data_bucket_force_destroy

  lifecycle {
    precondition {
      condition     = length(local.tpcds_data_bucket) <= 63
      error_message = "TPC-DS bucket name ${local.tpcds_data_bucket} is longer than 63 characters; use a shorter --prefix."
    }
  }
}

resource "aws_s3_bucket_ownership_controls" "tpcds_data" {
  bucket = aws_s3_bucket.tpcds_data.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "tpcds_data" {
  bucket                  = aws_s3_bucket.tpcds_data.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tpcds_data" {
  bucket = aws_s3_bucket.tpcds_data.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

output "tpcds_data_bucket" {
  description = "S3 bucket for Spark TPC-DS benchmark data"
  value       = aws_s3_bucket.tpcds_data.bucket
}

#---------------------------------------------------------------
# Access for Spark jobs: the same team roles that get the spark_jobs policy (infra/terraform/teams.tf),
# i.e. every team except Flink. Read/write/list on this bucket only.
#---------------------------------------------------------------
data "aws_iam_policy_document" "tpcds_data" {
  statement {
    sid       = "TpcdsBucketList"
    effect    = "Allow"
    resources = [aws_s3_bucket.tpcds_data.arn]
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
  }
  statement {
    sid       = "TpcdsObjects"
    effect    = "Allow"
    resources = ["${aws_s3_bucket.tpcds_data.arn}/*"]
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:AbortMultipartUpload",
      "s3:ListMultipartUploadParts",
    ]
  }
}

resource "aws_iam_policy" "tpcds_data" {
  name_prefix = "${local.name}-tpcds-data"
  description = "Read/write access to the TPC-DS benchmark data bucket"
  policy      = data.aws_iam_policy_document.tpcds_data.json
}

resource "aws_iam_role_policy_attachment" "tpcds_data" {
  for_each   = { for k, v in local.teams : k => v if !startswith(v.name, "flink") }
  role       = module.team_pod_identity[each.key].iam_role_name
  policy_arn = aws_iam_policy.tpcds_data.arn
}
