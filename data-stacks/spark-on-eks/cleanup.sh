#!/bin/bash
# Destroy the spark-on-eks stack with the same settings deploy.sh used.
# deploy.sh saves them in .deploy-params.env (prefix, VPC mode, subnet IDs, ...).
cd "$(dirname "$0")"

if [ -f .deploy-params.env ]; then
  echo "Using settings from .deploy-params.env:"
  sed 's/^/  /' .deploy-params.env
  source .deploy-params.env
else
  # Fallback when deploy.sh never saved settings
  PREFIX="${PREFIX-fs-}"
  export TF_VAR_name="${PREFIX}spark-on-eks"
  echo "No .deploy-params.env found; using TF_VAR_name=$TF_VAR_name"
fi

cd terraform/_local
source ./cleanup.sh
