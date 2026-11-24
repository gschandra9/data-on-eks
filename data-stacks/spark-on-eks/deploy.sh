#!/bin/bash
#
# Deploy the spark-on-eks stack.
#
#   ./deploy.sh --prefix fs- --vpc-mode create   [--vpc-config vpc-create.json]
#   ./deploy.sh --prefix fs- --vpc-mode existing  --vpc-config vpc.json
#
# Options:
#   --prefix <p>        Prefix for all created resource names (cluster: <p>spark-on-eks). Default: fs-
#   --vpc-mode <m>      create | existing. Default: create
#   --vpc-config <f>    JSON file with VPC settings (required for existing, optional for create)
#   --yes               Skip the confirmation prompt
#   --force             Deploy even if the existing Terraform state was created with other settings,
#                       or if leftovers of an earlier run were found (preflight)
#   -h, --help          Show this help
#
# vpc-config keys
#   existing: vpc_id or vpc_name, private_subnets, node_subnets, [public_subnets], [create_vpc_endpoints]
#             subnet entries are "subnet-..." or {"id": "subnet-...", "name": "..."}
#   create:   [vpc_cidr], [secondary_cidrs], [az_count], [public_subnet_cidrs], [private_subnet_cidrs],
#             [node_subnet_cidrs], [vpc_ipv6], [single_nat_gateway], [create_vpc_endpoints]
#             anything not set uses the defaults in terraform/vpc-variables.tf and infra/terraform/variables.tf
#   create_vpc_endpoints: "auto" (default) | true | false
#             auto: existing mode checks the VPC and creates only the S3 / S3 Express endpoints that are
#             missing; create mode always creates them (new VPC)
#   create_interface_endpoints (existing mode only): false (default) | "auto" | true
#             Interface endpoints (ec2, ecr.api, ecr.dkr, sts, eks, eks-auth, logs, sqs, ssm, elasticloadbalancing)
#             in the node subnets. Needed when the node subnets have no NAT/internet route, otherwise
#             nodes never join the cluster. auto: create only the services the VPC doesn't have yet.
#   update_s3_endpoint_policy (existing mode only): false (default) | true
#             Add the ECR image-layer bucket to the policy of the VPC's existing S3 endpoints. Needed when
#             their policy only allows other buckets (image pulls fail with 403). cleanup.sh resets the
#             policy to the AWS default (full access).
#   TPC-DS data bucket (always): <prefix>spark-benchmarks-tpcds-data-<region>-<account id>. Not force-destroyed:
#             cleanup.sh keeps it when it holds data; the next deploy.sh adopts the existing bucket.
#   node_http_proxy (both modes): "http://host[:port]". Nodes (containerd, kubelet), the Karpenter
#             controller and the Argo CD repo-server use this proxy for internet access. AWS services with
#             a VPC endpoint bypass it. Use it when the node subnets have no direct internet access.

# The whole script is one { ... } block: bash reads all of it before running anything, so editing
# this file while it runs cannot break the run in progress (bash otherwise reads scripts as it goes).
{
set -e

# --- Configuration ---
STACKS="spark-on-eks"
TERRAFORM_DIR="terraform"
AWS_REGION="${AWS_REGION:-us-west-2}"
KUBECONFIG_FILE="kubeconfig.yaml"
PARAMS_FILE=".deploy-params.env"   # saved settings, reused by cleanup.sh

usage() { sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; }
die()   { echo "ERROR: $*" >&2; exit 1; }

# --- Arguments ---
PREFIX="${PREFIX-fs-}"
VPC_MODE="create"
VPC_CONFIG=""
ASSUME_YES=false
FORCE=false

while [ $# -gt 0 ]; do
  case "$1" in
    --prefix)     [ $# -ge 2 ] || die "--prefix needs a value"; PREFIX="$2"; shift 2 ;;
    --vpc-mode)   [ $# -ge 2 ] || die "--vpc-mode needs a value"; VPC_MODE="$2"; shift 2 ;;
    --vpc-config) [ $# -ge 2 ] || die "--vpc-config needs a value"; VPC_CONFIG="$2"; shift 2 ;;
    --yes|-y)     ASSUME_YES=true; shift ;;
    --force)      FORCE=true; shift ;;
    -h|--help)    usage; exit 0 ;;
    *)            usage; die "unknown option: $1" ;;
  esac
done
set --   # install.sh is sourced below; don't pass our arguments to it

case "$VPC_MODE" in create|existing) ;; *) die "--vpc-mode must be 'create' or 'existing'" ;; esac
[[ "$PREFIX" =~ ^[a-z0-9-]*$ ]] || die "--prefix may only contain lowercase letters, digits and '-'"
[ "$VPC_MODE" = "existing" ] && [ -z "$VPC_CONFIG" ] && die "--vpc-mode existing requires --vpc-config <file>"

# Resolve the config path before changing directory
if [ -n "$VPC_CONFIG" ]; then
  [ -f "$VPC_CONFIG" ] || die "vpc config not found: $VPC_CONFIG"
  VPC_CONFIG="$(cd "$(dirname "$VPC_CONFIG")" && pwd)/$(basename "$VPC_CONFIG")"
fi

# Run from the stack directory (install.sh uses the current directory)
cd "$(dirname "$0")"

command -v jq >/dev/null || die "jq is required"

# --- Translate settings into Terraform variables (TF_VAR_*) ---
export TF_VAR_name="${PREFIX}${STACKS}"
export TF_VAR_vpc_mode="$VPC_MODE"
TF_VARS=(TF_VAR_name TF_VAR_vpc_mode)

# set_tf_var <terraform var> <jq expression>: export TF_VAR_<var> if the key is present
set_tf_var() {
  local var=$1 expr=$2 val
  # missing/null -> not set (Terraform default); false and 0 are kept
  val=$(jq -c "($expr) | if . == null then empty else . end" "$VPC_CONFIG") || die "invalid value for $var in $VPC_CONFIG"
  [ -z "$val" ] && return 0
  # strings are passed raw, lists/bools/numbers as JSON (Terraform parses them)
  if jq -e 'type == "string"' <<<"$val" >/dev/null; then val=$(jq -r . <<<"$val"); fi
  export "TF_VAR_${var}=${val}"
  TF_VARS+=("TF_VAR_${var}")
}

SUBNET_IDS='if . == null then empty else [ .[] | if type == "object" then .id else . end ] end'

if [ -n "$VPC_CONFIG" ]; then
  jq -e 'type == "object"' "$VPC_CONFIG" >/dev/null 2>&1 || die "$VPC_CONFIG is not a JSON object"

  if [ "$VPC_MODE" = "existing" ]; then
    ALLOWED='["vpc_id","vpc_name","public_subnets","private_subnets","node_subnets","create_vpc_endpoints","create_interface_endpoints","update_s3_endpoint_policy","node_http_proxy"]'
  else
    ALLOWED='["vpc_cidr","secondary_cidrs","az_count","public_subnet_cidrs","private_subnet_cidrs","node_subnet_cidrs","vpc_ipv6","single_nat_gateway","create_vpc_endpoints","node_http_proxy"]'
    # (create_vpc_endpoints is handled in the S3 endpoint section below)
  fi
  UNKNOWN=$(jq -r --argjson ok "$ALLOWED" 'keys - $ok | join(", ")' "$VPC_CONFIG")
  [ -z "$UNKNOWN" ] || die "unsupported keys for --vpc-mode $VPC_MODE in $VPC_CONFIG: $UNKNOWN"

  if [ "$VPC_MODE" = "existing" ]; then
    set_tf_var vpc_id             '.vpc_id'
    set_tf_var vpc_name           '.vpc_name'
    set_tf_var public_subnet_ids  ".public_subnets  | $SUBNET_IDS"
    set_tf_var private_subnet_ids ".private_subnets | $SUBNET_IDS"
    set_tf_var node_subnet_ids    ".node_subnets    | $SUBNET_IDS"

    [ -n "${TF_VAR_vpc_id:-}${TF_VAR_vpc_name:-}" ] || die "$VPC_CONFIG needs vpc_id or vpc_name"
    [ "$(jq 'length' <<<"${TF_VAR_private_subnet_ids:-[]}")" -gt 0 ] || die "$VPC_CONFIG needs private_subnets"
    [ "$(jq 'length' <<<"${TF_VAR_node_subnet_ids:-[]}")" -ge 2 ]   || die "$VPC_CONFIG needs at least 2 node_subnets"
    ALL_IDS=$(jq -n --argjson a "${TF_VAR_public_subnet_ids:-[]}" --argjson b "${TF_VAR_private_subnet_ids:-[]}" --argjson c "${TF_VAR_node_subnet_ids:-[]}" '$a + $b + $c')
    BAD=$(jq -r '[.[] | select(test("^subnet-[0-9a-f]+$") | not)] | join(", ")' <<<"$ALL_IDS")
    [ -z "$BAD" ] || die "invalid subnet IDs in $VPC_CONFIG: $BAD"
    # node_subnets may overlap private_subnets (nodes can run in the private subnets).
    # Duplicates inside one list, or public subnets reused as private/node subnets, are errors.
    DUP=$(jq -nr --argjson pub "${TF_VAR_public_subnet_ids:-[]}" --argjson prv "${TF_VAR_private_subnet_ids:-[]}" --argjson node "${TF_VAR_node_subnet_ids:-[]}" '
      def dups: group_by(.) | map(select(length > 1) | .[0]);
      ( ($pub | dups) + ($prv | dups) + ($node | dups)
        + ($pub - ($pub - $prv)) + ($pub - ($pub - $node)) ) | unique | join(", ")')
    [ -z "$DUP" ] || die "invalid duplicate subnet IDs in $VPC_CONFIG (only node_subnets may overlap private_subnets): $DUP"
  else
    set_tf_var vpc_cidr             '.vpc_cidr'
    set_tf_var secondary_cidrs      '.secondary_cidrs'
    set_tf_var az_count             '.az_count'
    set_tf_var public_subnet_cidrs  '.public_subnet_cidrs'
    set_tf_var private_subnet_cidrs '.private_subnet_cidrs'
    set_tf_var node_subnet_cidrs    '.node_subnet_cidrs'
    set_tf_var vpc_ipv6             '.vpc_ipv6'
    set_tf_var single_nat_gateway   '.single_nat_gateway'
  fi

  # Proxy for node/internet traffic (both modes): http://host[:port], no credentials
  set_tf_var node_http_proxy '.node_http_proxy'
  if [ -n "${TF_VAR_node_http_proxy:-}" ]; then
    [[ "$TF_VAR_node_http_proxy" =~ ^https?://[A-Za-z0-9._-]+(:[0-9]+)?$ ]] \
      || die "node_http_proxy must look like http://host[:port] (no credentials or path), got: $TF_VAR_node_http_proxy"
  fi
fi

# --- S3 VPC endpoints: create only the ones the VPC doesn't already have ---
#   create_vpc_endpoints in --vpc-config: "auto" (default) | true | false
#     auto  -> check the VPC; Terraform creates each S3 endpoint that is missing
#     true  -> always create (fails if the VPC already has one)
#     false -> never create
ENDPOINTS_MODE="auto"
if [ -n "$VPC_CONFIG" ]; then
  ENDPOINTS_MODE=$(jq -r 'if has("create_vpc_endpoints") then .create_vpc_endpoints | tostring else "auto" end' "$VPC_CONFIG")
fi
case "$ENDPOINTS_MODE" in auto|true|false) ;; *) die "create_vpc_endpoints must be \"auto\", true or false (got: $ENDPOINTS_MODE)" ;; esac

# Endpoints this deployment created carry the tag data-on-eks:deployment=<name> (see terraform/vpc.tf);
# they don't count as "already existing", otherwise a re-deploy would destroy them.
OWN_ENDPOINT_TAG="${TF_VAR_name}"

# existing_endpoints <vpc-id> <service suffix>: IDs of active endpoints for the service not created by this deployment
existing_endpoints() {
  aws ec2 describe-vpc-endpoints --region "$AWS_REGION" \
    --filters "Name=vpc-id,Values=$1" "Name=service-name,Values=com.amazonaws.${AWS_REGION}.$2" \
    --query "VpcEndpoints[?State!='deleted' && State!='deleting' && State!='rejected' && State!='failed' && State!='expired'] | [?!(Tags[?Key=='data-on-eks:deployment' && Value=='${OWN_ENDPOINT_TAG}'])].VpcEndpointId" \
    --output text
}

if [ "$VPC_MODE" = "create" ] || [ "$ENDPOINTS_MODE" != "auto" ]; then
  # New VPC has no endpoints; or the user decided explicitly
  CREATE_S3_ENDPOINT=$([ "$ENDPOINTS_MODE" = "false" ] && echo false || echo true)
  CREATE_S3EXPRESS_ENDPOINT=$CREATE_S3_ENDPOINT
else
  command -v aws >/dev/null || die "aws CLI is required"
  # Resolve the VPC ID when only vpc_name is given
  EP_VPC_ID="${TF_VAR_vpc_id:-}"
  if [ -z "$EP_VPC_ID" ]; then
    EP_VPC_ID=$(aws ec2 describe-vpcs --region "$AWS_REGION" --filters "Name=tag:Name,Values=$TF_VAR_vpc_name" \
      --query 'Vpcs[].VpcId' --output text) || die "could not look up VPC '$TF_VAR_vpc_name'"
    [ -n "$EP_VPC_ID" ] || die "no VPC named '$TF_VAR_vpc_name' in $AWS_REGION"
    [ "$(wc -w <<<"$EP_VPC_ID")" -eq 1 ] || die "more than one VPC named '$TF_VAR_vpc_name': $EP_VPC_ID. Set vpc_id instead."
  fi

  echo "Checking $EP_VPC_ID for existing S3 endpoints..."
  S3_EPS=$(existing_endpoints "$EP_VPC_ID" s3)               || die "could not list VPC endpoints (check AWS credentials and region)"
  S3EXPRESS_EPS=$(existing_endpoints "$EP_VPC_ID" s3express) || die "could not list VPC endpoints (check AWS credentials and region)"

  if [ -n "$S3_EPS" ]; then
    echo "  s3:        found $S3_EPS -> not creating"
    CREATE_S3_ENDPOINT=false
  else
    echo "  s3:        none -> Terraform will create it"
    CREATE_S3_ENDPOINT=true
  fi
  if [ -n "$S3EXPRESS_EPS" ]; then
    echo "  s3express: found $S3EXPRESS_EPS -> not creating"
    CREATE_S3EXPRESS_ENDPOINT=false
  else
    echo "  s3express: none -> Terraform will create it"
    CREATE_S3EXPRESS_ENDPOINT=true
  fi
fi
export TF_VAR_create_s3_endpoint="$CREATE_S3_ENDPOINT"
export TF_VAR_create_s3express_endpoint="$CREATE_S3EXPRESS_ENDPOINT"
TF_VARS+=(TF_VAR_create_s3_endpoint TF_VAR_create_s3express_endpoint)

# --- Interface endpoints (existing VPC without NAT access from the node subnets) ---
IFACE_SERVICES=(ec2 ecr.api ecr.dkr sts eks eks-auth logs sqs ssm elasticloadbalancing)
IFACE_MODE="false"
if [ "$VPC_MODE" = "existing" ] && [ -n "$VPC_CONFIG" ]; then
  IFACE_MODE=$(jq -r 'if has("create_interface_endpoints") then .create_interface_endpoints | tostring else "false" end' "$VPC_CONFIG")
fi
case "$IFACE_MODE" in auto|true|false) ;; *) die "create_interface_endpoints must be \"auto\", true or false (got: $IFACE_MODE)" ;; esac

if [ "$IFACE_MODE" != "false" ]; then
  command -v aws >/dev/null || die "aws CLI is required"
  if [ "$IFACE_MODE" = "true" ]; then
    IFACE_CREATE=("${IFACE_SERVICES[@]}")
  else
    # Resolve the VPC ID (may already be set by the S3 check above)
    EP_VPC_ID="${EP_VPC_ID:-${TF_VAR_vpc_id:-}}"
    if [ -z "$EP_VPC_ID" ]; then
      EP_VPC_ID=$(aws ec2 describe-vpcs --region "$AWS_REGION" --filters "Name=tag:Name,Values=$TF_VAR_vpc_name" \
        --query 'Vpcs[].VpcId' --output text) || die "could not look up VPC '$TF_VAR_vpc_name'"
      [ "$(wc -w <<<"$EP_VPC_ID")" -eq 1 ] || die "expected exactly one VPC named '$TF_VAR_vpc_name', found: ${EP_VPC_ID:-none}. Set vpc_id instead."
    fi
    echo "Checking $EP_VPC_ID for existing interface endpoints..."
    IFACE_CREATE=()
    for svc in "${IFACE_SERVICES[@]}"; do
      found=$(existing_endpoints "$EP_VPC_ID" "$svc") || die "could not list VPC endpoints (check AWS credentials and region)"
      if [ -n "$found" ]; then
        echo "  $svc: found $found -> not creating"
      else
        echo "  $svc: none -> Terraform will create it"
        IFACE_CREATE+=("$svc")
      fi
    done
  fi
  if [ ${#IFACE_CREATE[@]} -gt 0 ]; then
    export TF_VAR_create_interface_endpoints=$(printf '%s\n' "${IFACE_CREATE[@]}" | jq -R . | jq -sc .)
  else
    export TF_VAR_create_interface_endpoints="[]"
  fi
  TF_VARS+=(TF_VAR_create_interface_endpoints)
fi

# --- Existing S3 endpoint policy: allow the ECR image-layer bucket ---
#   update_s3_endpoint_policy (existing mode): false (default) | true
#   An S3 endpoint with a restrictive policy returns 403 for ECR image layers, so pods such as
#   aws-node can't start. true: Terraform adds the ECR layer bucket to the policy of the VPC's
#   existing S3 endpoints (aws_vpc_endpoint_policy). NOTE: cleanup.sh resets those policies to the
#   AWS default (full access) because Terraform owns the policy while the deployment exists.
UPDATE_S3_POLICY="false"
if [ "$VPC_MODE" = "existing" ] && [ -n "$VPC_CONFIG" ]; then
  UPDATE_S3_POLICY=$(jq -r 'if has("update_s3_endpoint_policy") then .update_s3_endpoint_policy | tostring else "false" end' "$VPC_CONFIG")
fi
case "$UPDATE_S3_POLICY" in true|false) ;; *) die "update_s3_endpoint_policy must be true or false (got: $UPDATE_S3_POLICY)" ;; esac

if [ "$UPDATE_S3_POLICY" = "true" ]; then
  command -v aws >/dev/null || die "aws CLI is required"
  EP_VPC_ID="${EP_VPC_ID:-${TF_VAR_vpc_id:-}}"
  if [ -z "$EP_VPC_ID" ]; then
    EP_VPC_ID=$(aws ec2 describe-vpcs --region "$AWS_REGION" --filters "Name=tag:Name,Values=$TF_VAR_vpc_name" \
      --query 'Vpcs[].VpcId' --output text) || die "could not look up VPC '$TF_VAR_vpc_name'"
    [ "$(wc -w <<<"$EP_VPC_ID")" -eq 1 ] || die "expected exactly one VPC named '$TF_VAR_vpc_name', found: ${EP_VPC_ID:-none}. Set vpc_id instead."
  fi
  # Only endpoints this deployment did not create (those get the default policy)
  POLICY_EPS=$(existing_endpoints "$EP_VPC_ID" s3) || die "could not list VPC endpoints (check AWS credentials and region)"
  if [ -n "$POLICY_EPS" ]; then
    echo "Existing S3 endpoints whose policy will allow the ECR layer bucket: $POLICY_EPS"
  else
    echo "No existing S3 endpoint in $EP_VPC_ID; nothing to update"
  fi
  export TF_VAR_s3_endpoint_policy_ids=$(printf '%s\n' $POLICY_EPS | jq -R 'select(. != "")' | jq -sc .)
  TF_VARS+=(TF_VAR_s3_endpoint_policy_ids)
fi

# --- TPC-DS data bucket: adopt a bucket kept by an earlier cleanup ---
# terraform/tpcds-data-bucket.tf creates <prefix>spark-benchmarks-tpcds-data-<region>-<account id>.
# cleanup.sh keeps that bucket when it holds data (it only removes it from the state), so on the next
# deploy it already exists: Terraform then imports it instead of failing with BucketAlreadyOwnedByYou.
command -v aws >/dev/null || die "aws CLI is required"
TF_REGION=$(grep -E '^[[:space:]]*region[[:space:]]*=' "$TERRAFORM_DIR/data-stack.tfvars" 2>/dev/null | sed -E 's/.*=[[:space:]]*"([^"]*)".*/\1/')
TF_REGION="${TF_REGION:-$AWS_REGION}"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text) || die "could not read the AWS account ID (check credentials)"
TPCDS_BUCKET="${PREFIX}spark-benchmarks-tpcds-data-${TF_REGION}-${ACCOUNT_ID}"
[ ${#TPCDS_BUCKET} -le 63 ] || die "TPC-DS bucket name $TPCDS_BUCKET is longer than 63 characters; use a shorter --prefix"
TPCDS_ADOPT=false
TPCDS_STATE="$TERRAFORM_DIR/_local/terraform.tfstate"
if [ -f "$TPCDS_STATE" ] && jq -e '.resources[]? | select(.mode=="managed" and .type=="aws_s3_bucket" and .name=="tpcds_data")' "$TPCDS_STATE" >/dev/null 2>&1; then
  echo "TPC-DS data bucket: $TPCDS_BUCKET (managed by Terraform)"
elif HB_OUT=$(aws s3api head-bucket --region "$TF_REGION" --bucket "$TPCDS_BUCKET" 2>&1); then
  echo "TPC-DS data bucket: $TPCDS_BUCKET exists (kept by an earlier cleanup) -> Terraform adopts it"
  TPCDS_ADOPT=true
elif grep -qE "403|Forbidden" <<<"$HB_OUT"; then
  die "S3 bucket name $TPCDS_BUCKET is taken by another account (or access is denied). Use another --prefix."
else
  echo "TPC-DS data bucket: $TPCDS_BUCKET will be created"
fi
export TF_VAR_tpcds_data_bucket_adopt="$TPCDS_ADOPT"
TF_VARS+=(TF_VAR_tpcds_data_bucket_adopt)

# -var-file values override TF_VAR_*, so these must not be set in data-stack.tfvars
TFVARS_FILE="$TERRAFORM_DIR/data-stack.tfvars"
for v in "${TF_VARS[@]}"; do
  key=${v#TF_VAR_}
  if grep -qE "^[[:space:]]*${key}[[:space:]]*=" "$TFVARS_FILE" 2>/dev/null; then
    die "'$key' is set in $TFVARS_FILE and would override the deploy.sh value. Remove it from the tfvars file."
  fi
done

# --- Guard against changing settings of an existing deployment ---
STATE_FILE="$TERRAFORM_DIR/_local/terraform.tfstate"
STATE_RESOURCES=0
[ -f "$STATE_FILE" ] && STATE_RESOURCES=$(jq '.resources | length' "$STATE_FILE" 2>/dev/null || echo 0)
NEW_PARAMS=$(for v in "${TF_VARS[@]}"; do printf 'export %s=%q\n' "$v" "${!v}"; done)
# Interface endpoints can be added to a running deployment, so they don't count as a settings change
# (tpcds_data_bucket_adopt changes between runs by design: true only on the run that re-adopts a kept bucket)
strip_endpoints() { grep -vE 'TF_VAR_(create_interface_endpoints|s3_endpoint_policy_ids|tpcds_data_bucket_adopt)=' || true; }
if [ "$STATE_RESOURCES" -gt 0 ] && [ -f "$PARAMS_FILE" ] && [ "$(strip_endpoints <<<"$NEW_PARAMS")" != "$(strip_endpoints <"$PARAMS_FILE")" ] && [ "$FORCE" != true ]; then
  echo "Existing deployment ($STATE_RESOURCES resources in state) was created with:"
  sed 's/^/  /' "$PARAMS_FILE"
  echo "New settings:"
  sed 's/^/  /' <<<"$NEW_PARAMS"
  die "settings differ from the existing deployment. Run cleanup.sh first, or pass --force."
fi

# --- Preflight: a fresh deployment must not collide with leftovers of an earlier run ---
# Only when Terraform state is empty. Leftovers (cluster, node role, log group, own VPC endpoints,
# nodes) make Terraform fail with "already exists". ./cleanup.sh removes them; it never touches the
# existing VPC, subnets or route tables.
if [ "$STATE_RESOURCES" -eq 0 ] && [ "$FORCE" != true ]; then
  command -v aws >/dev/null || die "aws CLI is required"
  aws sts get-caller-identity >/dev/null 2>&1 || die "no valid AWS credentials (aws sts get-caller-identity failed)"
  CONFLICTS=()
  aws eks describe-cluster --region "$AWS_REGION" --name "$TF_VAR_name" >/dev/null 2>&1 \
    && CONFLICTS+=("EKS cluster $TF_VAR_name")
  aws iam get-role --role-name "karpenter-doeks-$TF_VAR_name" >/dev/null 2>&1 \
    && CONFLICTS+=("IAM role karpenter-doeks-$TF_VAR_name")
  [ -n "$(aws logs describe-log-groups --region "$AWS_REGION" --log-group-name-prefix "/aws/eks/$TF_VAR_name/cluster" \
        --query "logGroups[?logGroupName=='/aws/eks/$TF_VAR_name/cluster'].logGroupName" --output text 2>/dev/null)" ] \
    && CONFLICTS+=("CloudWatch log group /aws/eks/$TF_VAR_name/cluster")
  OWN_EPS=$(aws ec2 describe-vpc-endpoints --region "$AWS_REGION" --filters "Name=tag:data-on-eks:deployment,Values=${OWN_ENDPOINT_TAG}" \
    --query "VpcEndpoints[?State!='deleted' && State!='deleting'].VpcEndpointId" --output text 2>/dev/null || true)
  [ -n "$OWN_EPS" ] && CONFLICTS+=("VPC endpoints from an earlier run: $OWN_EPS")
  NODES=$(aws ec2 describe-instances --region "$AWS_REGION" \
    --filters "Name=tag:eks:eks-cluster-name,Values=$TF_VAR_name" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null || true)
  [ -n "$NODES" ] && CONFLICTS+=("EC2 instances of the cluster: $NODES")
  if [ ${#CONFLICTS[@]} -gt 0 ]; then
    printf '  - %s\n' "${CONFLICTS[@]}" >&2
    die "leftovers from an earlier deployment found (listed above). Run ./cleanup.sh first, or pass --force to ignore."
  fi
  echo "Preflight OK: no leftovers of $TF_VAR_name found."
fi

# --- Summary ---
echo "----------------------------------------------------------------"
echo " Stack:        $STACKS"
echo " Region:       $AWS_REGION"
echo " Name:         $TF_VAR_name"
echo " VPC mode:     $VPC_MODE"
[ -n "$VPC_CONFIG" ] && echo " VPC config:   $VPC_CONFIG"
for v in "${TF_VARS[@]}"; do
  case "$v" in TF_VAR_name|TF_VAR_vpc_mode) ;; *) printf ' %-22s %s\n' "${v#TF_VAR_}:" "${!v}" ;; esac
done
echo "----------------------------------------------------------------"
if [ "$ASSUME_YES" != true ]; then
  read -r -p "Proceed with deployment? [y/N] " ans
  [[ "$ans" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 1; }
fi

# Save settings so cleanup.sh destroys with the same variables
printf '%s\n' "$NEW_PARAMS" > "$PARAMS_FILE"

# --- Get Repo Root ---
REPO_PATH=$(git rev-parse --show-toplevel)

# --- Source and Execute the Main Deployment Engine ---
# The centralized install.sh handles all the heavy lifting.
source $REPO_PATH/infra/terraform/install.sh

# --- Post-Deployment Steps ---
# Steps specific to this stack can be added here.
print_status "Running stack-specific post-deployment steps..."

# Backup the state file from the _local directory
cp "$TERRAFORM_DIR/_local/terraform.tfstate" "$TERRAFORM_DIR/terraform.tfstate.bak"
print_status "Backed up terraform.tfstate."

# Setup kubeconfig
setup_kubeconfig

# Get ArgoCD admin password
export KUBECONFIG=$KUBECONFIG_FILE
ARGOCD_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)

print_next_steps

# Exit inside the block, so nothing appended to the file during a run is ever executed.
exit
}
