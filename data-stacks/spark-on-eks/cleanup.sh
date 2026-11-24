#!/bin/bash
#
# Destroy the spark-on-eks stack and remove its leftovers so the next ./deploy.sh starts clean.
#
#   ./cleanup.sh [--yes] [--dry-run] [--delete-tpcds-data]
#
#   --yes       Don't ask before deleting leftovers or before the AWS CLI fallback
#   --dry-run   Only report: state, cluster, Kubernetes access and leftovers. Deletes nothing.
#   --delete-tpcds-data  Also delete the TPC-DS data bucket and ALL its objects. Without it the bucket is kept
#               when it holds data (asked interactively; --yes alone keeps it) and the next deploy.sh adopts it.
#
# It is safe to run again after any failure (every step is idempotent). Output is also written to
# cleanup-<timestamp>.log in this folder.
#
# NEVER touched: an existing VPC and everything in it (subnets, route tables, NAT / internet gateways,
# pre-existing VPC endpoints). Terraform only reads them in --vpc-mode existing, the sweep deletes only
# resources carrying this deployment's name/tags, and every AWS call goes through awsw(), which refuses
# any call that would delete or change VPC networking (vpc, subnet, route, gateway, ACL, ...).
#
# Flow
#   0. checks: credentials, tools, lock, Terraform working directory (_local) in sync with the code
#   1. figure out the state of the cluster (exists? reachable with kubectl?)
#        gone / unreachable -> drop Helm + Kubernetes resources from the Terraform state (they disappear
#                              with the cluster; a state backup is written first)
#        reachable          -> delete Karpenter NodePools, Argo CD applications, LoadBalancer services
#   2. terraform destroy in three phases (manifests, module.eks, rest), up to 3 attempts; the error text
#      decides what happens between attempts (unreachable cluster, dependency still held, state lock,
#      expired credentials)
#   3. if Terraform cannot delete the cluster: delete it with the AWS CLI (asks first), then retry
#   4. sweep leftovers tagged for this deployment: nodes, load balancers, own VPC endpoints, EBS volumes,
#      log group, Karpenter node role, KMS alias, ENIs, security groups
#   5. when nothing is left: remove local deployment files (.deploy-params.env, kubeconfig.yaml, empty state)

# The whole script is one { ... } block: bash reads all of it before running anything, so editing
# this file while it runs cannot break the run in progress (bash otherwise reads scripts as it goes).
{
cd "$(dirname "$0")" || exit 1
STACK_DIR=$(pwd)

ASSUME_YES=false
DRY_RUN=false
DELETE_TPCDS=false
while [ $# -gt 0 ]; do
  case "$1" in
    --yes|-y)   ASSUME_YES=true; shift ;;
    --dry-run)  DRY_RUN=true; shift ;;
    --delete-tpcds-data) DELETE_TPCDS=true; shift ;;
    -h|--help)  sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)          echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

LOG="$STACK_DIR/cleanup-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG") 2>&1
echo "cleanup.sh started $(date '+%Y-%m-%d %H:%M:%S %Z'); log: $LOG"

die() { echo "ERROR: $*" >&2; exit 1; }
log() { echo; echo "=== $* ==="; }

PARAMS_FILE=".deploy-params.env"
TF_DIR="$STACK_DIR/terraform"
LOCAL_DIR="$TF_DIR/_local"
STATE_FILE="$LOCAL_DIR/terraform.tfstate"
TFVARS="$TF_DIR/data-stack.tfvars"

#---------------------------------------------------------------
# 0. settings, tools, safety
#---------------------------------------------------------------
if [ -f "$PARAMS_FILE" ]; then
  echo "Using settings from $PARAMS_FILE:"
  sed 's/^/  /' "$PARAMS_FILE"
  # shellcheck disable=SC1090
  source "$PARAMS_FILE"
else
  PREFIX="${PREFIX-fs-}"
  export TF_VAR_name="${PREFIX}spark-on-eks"
  echo "No $PARAMS_FILE found; using TF_VAR_name=$TF_VAR_name"
fi
NAME="$TF_VAR_name"
[[ "$NAME" =~ ^[a-z0-9-]*spark-on-eks$ ]] || die "unexpected deployment name '$NAME'"
VPC_MODE="${TF_VAR_vpc_mode:-create}"
# The import block in terraform/tpcds-data-bucket.tf must never run during cleanup
export TF_VAR_tpcds_data_bucket_adopt=false

REGION=$(grep -E '^[[:space:]]*region[[:space:]]*=' "$TFVARS" 2>/dev/null | sed -E 's/.*=[[:space:]]*"([^"]*)".*/\1/')
AWS_REGION="${REGION:-${AWS_REGION:-us-west-2}}"
export AWS_REGION

for t in aws terraform jq; do command -v "$t" >/dev/null || die "$t is required"; done
HAVE_KUBECTL=false; command -v kubectl >/dev/null && HAVE_KUBECTL=true

# Every AWS call goes through here. Defense in depth for the rule "never touch the VPC network".
awsw() {
  case "$*" in
    *delete-vpc\ *|*delete-vpc|*delete-subnet*|*delete-route*|*delete-nat-gateway*|*delete-internet-gateway*|\
    *delete-egress-only*|*detach-internet-gateway*|*disassociate-route-table*|*associate-route-table*|\
    *replace-route*|*create-route\ *|*delete-network-acl*|*replace-network-acl*|*delete-dhcp*|*delete-transit*|\
    *modify-subnet*|*modify-vpc-attribute*|*disassociate-vpc-cidr*|*delete-customer-gateway*)
      echo "REFUSED: aws $* (cleanup.sh never modifies VPC networking)" >&2; return 99 ;;
  esac
  aws --region "$AWS_REGION" "$@"
}

need_creds() {
  awsw sts get-caller-identity >/dev/null 2>&1 && return 0
  echo "ERROR: AWS credentials are missing or expired. Log in again and re-run ./cleanup.sh (it resumes)." >&2
  return 1
}
need_creds || exit 1
echo "AWS identity: $(awsw sts get-caller-identity --query Arn --output text)   region: $AWS_REGION"

# one cleanup at a time
LOCKDIR="$STACK_DIR/.cleanup.lock"
if ! mkdir "$LOCKDIR" 2>/dev/null; then
  die "another cleanup.sh seems to be running ($LOCKDIR exists). If not, remove that folder and retry."
fi
trap 'rmdir "$LOCKDIR" 2>/dev/null' EXIT

confirm() {
  [ "$ASSUME_YES" = true ] && return 0
  local ans
  if [ -r /dev/tty ]; then printf '%s [y/N] ' "$1" > /dev/tty; read -r ans < /dev/tty; else read -r -p "$1 [y/N] " ans; fi
  [[ "$ans" =~ ^[Yy]$ ]]
}

state_count() {
  local n=0
  [ -f "$STATE_FILE" ] && n=$(jq '.resources | length' "$STATE_FILE" 2>/dev/null || echo 0)
  echo "${n:-0}"
}

# Same preparation install.sh does: Terraform runs from _local = infra/terraform + this stack's overlay.
# Done again here so destroy uses the current code, and works even if _local was cleaned.
prepare_local() {
  local repo; repo=$(git rev-parse --show-toplevel 2>/dev/null) || die "run inside the git repository"
  mkdir -p "$LOCAL_DIR"
  find "$LOCAL_DIR" -mindepth 1 -maxdepth 1 -not -name '.terraform' -not -name '.terraform.lock.hcl' -not -name 'terraform.tfstate*' -exec rm -rf {} +
  cp -r "$repo/infra/terraform/"* "$LOCAL_DIR/"
  tar -C "$TF_DIR" --exclude='_local' --exclude='*.tfstate*' --exclude='.terraform' -cf - . | tar -C "$LOCAL_DIR" -xf -
}

tf() { ( cd "$LOCAL_DIR" && terraform "$@" ); }

# With an existing VPC the state must not contain resources that create VPC networking.
if [ "$VPC_MODE" = "existing" ] && [ "$(state_count)" -gt 0 ]; then
  NET=$(jq -r '.resources[] | select(.mode=="managed") | select(.type|test("^aws_(vpc|subnet|route_table|route|nat_gateway|internet_gateway|egress_only_internet_gateway|vpc_ipv4_cidr_block_association|network_acl)$")) | .type' "$STATE_FILE" 2>/dev/null | sort -u)
  if [ -n "$NET" ]; then
    die "vpc_mode is 'existing' but the Terraform state manages VPC networking ($NET). Refusing to destroy; inspect: terraform -chdir=$LOCAL_DIR state list"
  fi
fi

#---------------------------------------------------------------
# 1. what is the cluster doing?
#---------------------------------------------------------------
cluster_status() {   # prints ACTIVE | CREATING | DELETING | FAILED | NOT_FOUND | UNKNOWN
  local out
  out=$(awsw eks describe-cluster --name "$NAME" --query 'cluster.status' --output text 2>&1)
  if [ $? -eq 0 ]; then echo "$out"; elif grep -q ResourceNotFoundException <<<"$out"; then echo NOT_FOUND; else echo UNKNOWN; fi
}

KCFG=$(mktemp -t cleanup-kubeconfig.XXXXXX)
k8s_ok() {           # kubectl can talk to the cluster with the current AWS identity
  [ "$HAVE_KUBECTL" = true ] || return 1
  awsw eks update-kubeconfig --name "$NAME" --kubeconfig "$KCFG" >/dev/null 2>&1 || return 1
  kubectl --kubeconfig "$KCFG" --request-timeout=20s get ns >/dev/null 2>&1
}

BACKED_UP=false
drop_in_cluster_state() {
  # Helm releases and Kubernetes objects can't be destroyed without the cluster; they vanish with it.
  local list
  list=$(tf state list 2>/dev/null | grep -E '(^|\.)(helm_release|kubectl_manifest|kubernetes_[a-z_]+)\.')
  [ -z "$list" ] && return 0
  if [ "$BACKED_UP" != true ]; then
    local b="$STACK_DIR/state-backup-$(date +%Y%m%d-%H%M%S).tfstate.bak"
    tf state pull > "$b" && echo "State backup: $b" && BACKED_UP=true
  fi
  echo "Removing in-cluster resources from the Terraform state:"
  while IFS= read -r r; do
    [ -z "$r" ] && continue
    tf state rm "$r" >/dev/null 2>&1 && echo "  removed: $r"
  done <<<"$list"
}

diagnose_k8s_access() {
  echo "kubectl cannot authenticate to $NAME. Your identity and the cluster's access entries:"
  echo "  caller:  $(awsw sts get-caller-identity --query Arn --output text)"
  awsw eks list-access-entries --cluster-name "$NAME" --output text 2>/dev/null | sed 's/^/  entry:   /'
}

K8S="unknown"
refresh_k8s_state() {
  CL_STATUS=$(cluster_status)
  case "$CL_STATUS" in
    NOT_FOUND) K8S="gone" ;;
    UNKNOWN)   K8S="broken" ;;
    *)         if k8s_ok; then K8S="ok"; else K8S="broken"; fi ;;
  esac
  echo "EKS cluster: $CL_STATUS   Kubernetes access: $K8S   Terraform state resources: $(state_count)"
}

#---------------------------------------------------------------
# leftovers (read-only discovery; used by --dry-run and the sweep)
#---------------------------------------------------------------
PROTECTED_ENDPOINTS=$(jq -r '.[]?' <<<"${TF_VAR_s3_endpoint_policy_ids:-[]}" 2>/dev/null)
nonempty() { grep . || true; }

find_instances() {
  { for f in "Name=tag:eks:eks-cluster-name,Values=$NAME" "Name=tag:eks:cluster-name,Values=$NAME" "Name=tag-key,Values=kubernetes.io/cluster/$NAME"; do
      awsw ec2 describe-instances --filters "$f" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
        --query 'Reservations[].Instances[].InstanceId' --output text
    done; } 2>/dev/null | tr '\t' '\n' | sort -u | nonempty
}
find_lbs() {
  { awsw resourcegroupstaggingapi get-resources --resource-type-filters elasticloadbalancing:loadbalancer \
      --tag-filters "Key=elbv2.k8s.aws/cluster,Values=$NAME" --query 'ResourceTagMappingList[].ResourceARN' --output text
    awsw resourcegroupstaggingapi get-resources --resource-type-filters elasticloadbalancing:loadbalancer \
      --tag-filters "Key=kubernetes.io/cluster/$NAME" --query 'ResourceTagMappingList[].ResourceARN' --output text
  } 2>/dev/null | tr '\t' '\n' | sort -u | nonempty
}
find_own_sgs() {
  { awsw ec2 describe-security-groups --filters "Name=tag-key,Values=kubernetes.io/cluster/$NAME" --query "SecurityGroups[?GroupName!='default'].GroupId" --output text
    awsw ec2 describe-security-groups --filters "Name=tag:aws:eks:cluster-name,Values=$NAME" --query "SecurityGroups[?GroupName!='default'].GroupId" --output text
    awsw ec2 describe-security-groups --filters "Name=tag:Name,Values=${NAME}-vpc-endpoint-*" --query "SecurityGroups[?GroupName!='default'].GroupId" --output text
  } 2>/dev/null | tr '\t' '\n' | sort -u | nonempty
}
find_own_endpoints() {   # tagged for this deployment, or attached to its endpoint security group; never protected ones
  local sgs sg out p
  sgs=$(awsw ec2 describe-security-groups --filters "Name=tag:Name,Values=${NAME}-vpc-endpoint-*" --query "SecurityGroups[?GroupName!='default'].GroupId" --output text 2>/dev/null | tr '\t' '\n' | nonempty)
  out=$( { awsw ec2 describe-vpc-endpoints --filters "Name=tag:data-on-eks:deployment,Values=${NAME}" \
             --query "VpcEndpoints[?State!='deleted' && State!='deleting'].VpcEndpointId" --output text
           for sg in $sgs; do
             awsw ec2 describe-vpc-endpoints --query "VpcEndpoints[?State!='deleted' && State!='deleting' && Groups[?GroupId=='$sg']].VpcEndpointId" --output text
           done; } 2>/dev/null | tr '\t' '\n' | sort -u | nonempty )
  for p in $PROTECTED_ENDPOINTS; do out=$(grep -vx "$p" <<<"$out"); done
  echo "$out" | nonempty
}
find_volumes() {
  local depid
  depid=$(grep -E '^[[:space:]]*deployment_id[[:space:]]*=' "$TFVARS" 2>/dev/null | sed -E 's/.*=[[:space:]]*"([^"]*)".*/\1/')
  { awsw ec2 describe-volumes --filters "Name=tag-key,Values=kubernetes.io/cluster/$NAME" "Name=status,Values=available" --query 'Volumes[].VolumeId' --output text
    [ -n "$depid" ] && awsw ec2 describe-volumes --filters "Name=tag:DeploymentId,Values=$depid" "Name=status,Values=available" --query 'Volumes[].VolumeId' --output text
  } 2>/dev/null | tr '\t' '\n' | sort -u | nonempty
}
LOG_GROUP="/aws/eks/$NAME/cluster"
find_log_group() { awsw logs describe-log-groups --log-group-name-prefix "$LOG_GROUP" --query "logGroups[?logGroupName=='$LOG_GROUP'].logGroupName" --output text 2>/dev/null; }
NODE_ROLE="karpenter-doeks-$NAME"
find_node_role() { aws iam get-role --role-name "$NODE_ROLE" --query 'Role.RoleName' --output text 2>/dev/null; }
KMS_ALIAS="alias/eks/$NAME"
find_kms_alias() { awsw kms list-aliases --query "Aliases[?AliasName=='$KMS_ALIAS'].AliasName" --output text 2>/dev/null; }
find_enis() { awsw ec2 describe-network-interfaces --filters "Name=tag:cluster.k8s.amazonaws.com/name,Values=$NAME" --query 'NetworkInterfaces[].[NetworkInterfaceId,Status]' --output text 2>/dev/null; }

report_leftovers() {
  echo "  instances:         $(find_instances | tr '\n' ' ')"
  echo "  load balancers:    $(find_lbs | tr '\n' ' ')"
  echo "  own VPC endpoints: $(find_own_endpoints | tr '\n' ' ')"
  echo "  EBS volumes:       $(find_volumes | tr '\n' ' ')"
  echo "  log group:         $(find_log_group)"
  echo "  node IAM role:     $(find_node_role)"
  echo "  KMS alias:         $(find_kms_alias)"
  echo "  tagged ENIs:       $(find_enis | awk '{print $1"("$2")"}' | tr '\n' ' ')"
  echo "  security groups:  $(find_own_sgs | tr '\n' ' ')"
}

terminate_instances() {
  local ids; ids=$(find_instances)
  [ -z "$ids" ] && return 0
  echo "Terminating instances: $(echo $ids)"
  awsw ec2 terminate-instances --instance-ids $ids >/dev/null
  awsw ec2 wait instance-terminated --instance-ids $ids 2>/dev/null
}

#---------------------------------------------------------------
# TPC-DS data bucket (terraform/tpcds-data-bucket.tf): keep its data unless deletion is explicit
#---------------------------------------------------------------
TPCDS_KEPT=""
tpcds_bucket_name() {   # from the Terraform state; empty when not managed
  [ -f "$STATE_FILE" ] || return 0
  jq -r '.resources[]? | select(.mode=="managed" and .type=="aws_s3_bucket" and .name=="tpcds_data") | .instances[0].attributes.bucket // empty' "$STATE_FILE" 2>/dev/null
}
tpcds_object_count() {  # 0 = empty; "?" = could not check
  local n
  n=$(awsw s3api list-objects-v2 --bucket "$1" --max-keys 1 --no-paginate --query 'KeyCount' --output text 2>/dev/null) || { echo "?"; return; }
  echo "${n:-0}"
}
handle_tpcds_bucket() {
  local b n r
  b=$(tpcds_bucket_name); [ -z "$b" ] && return 0
  n=$(tpcds_object_count "$b")
  if [ "$n" = "0" ]; then
    echo "TPC-DS data bucket $b is empty; Terraform deletes it."
    return 0
  fi
  if [ "$DELETE_TPCDS" = true ] || { [ "$ASSUME_YES" != true ] && confirm "TPC-DS data bucket $b contains data. Delete the bucket AND ALL ITS OBJECTS?"; }; then
    echo "Emptying $b (this can take a while for large datasets)..."
    awsw s3 rm "s3://$b" --recursive --only-show-errors || { echo "ERROR: could not empty $b"; return 1; }
    return 0
  fi
  echo "Keeping $b and its data: removing it from the Terraform state only (the next ./deploy.sh adopts it)."
  if [ "$BACKED_UP" != true ]; then
    local bk="$STACK_DIR/state-backup-$(date +%Y%m%d-%H%M%S).tfstate.bak"
    tf state pull > "$bk" && echo "State backup: $bk" && BACKED_UP=true
  fi
  for r in aws_s3_bucket_ownership_controls.tpcds_data aws_s3_bucket_public_access_block.tpcds_data \
           aws_s3_bucket_server_side_encryption_configuration.tpcds_data aws_s3_bucket.tpcds_data; do
    tf state list 2>/dev/null | grep -qx "$r" && tf state rm "$r" >/dev/null && echo "  removed from state: $r"
  done
  TPCDS_KEPT="$b"
}

#---------------------------------------------------------------
# dry run
#---------------------------------------------------------------
if [ "$DRY_RUN" = true ]; then
  log "DRY RUN (nothing is deleted)"
  refresh_k8s_state
  [ "$K8S" = "broken" ] && [ "$CL_STATUS" != "UNKNOWN" ] && diagnose_k8s_access
  echo "Leftovers found right now:"; report_leftovers
  TB=$(tpcds_bucket_name)
  if [ -n "$TB" ]; then
    if [ "$(tpcds_object_count "$TB")" = "0" ]; then echo "  TPC-DS data bucket: $TB (empty, would be deleted)"
    else echo "  TPC-DS data bucket: $TB (has data: kept unless --delete-tpcds-data or confirmed)"; fi
  fi
  rm -f "$KCFG"; exit 0
fi

#---------------------------------------------------------------
# 2. terraform destroy
#---------------------------------------------------------------
LAST_OUT=$(mktemp -t cleanup-tf.XXXXXX)

tf_destroy() {   # tf_destroy <label> [terraform args...]
  local label=$1; shift
  echo "--- terraform destroy: $label"
  local args=(destroy -auto-approve -input=false -lock-timeout=120s -var="region=$AWS_REGION")
  [ -f "$TFVARS" ] && args+=(-var-file=../data-stack.tfvars)
  ( cd "$LOCAL_DIR" && terraform "${args[@]}" "$@" ) 2>&1 | tee "$LAST_OUT"
  return "${PIPESTATUS[0]}"
}

graceful_k8s_steps() {   # only when kubectl works: let controllers release what they created
  local kc=(kubectl --kubeconfig "$KCFG" --request-timeout=60s)
  echo "Deleting Karpenter NodePools (nodes drain)..."
  "${kc[@]}" delete nodepool --all --wait=true --timeout=300s 2>&1 | tail -3
}
graceful_k8s_services() {
  local kc=(kubectl --kubeconfig "$KCFG" --request-timeout=60s)
  echo "Deleting Ingresses and LoadBalancer Services so their load balancers are removed..."
  "${kc[@]}" delete ingress -A --all --timeout=120s 2>&1 | tail -3
  "${kc[@]}" get svc -A --field-selector spec.type=LoadBalancer -o 'jsonpath={range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}' 2>/dev/null |
    while read -r ns svc; do [ -n "$svc" ] && "${kc[@]}" delete svc "$svc" -n "$ns" --timeout=120s 2>&1 | tail -1; done
}

destroy_all() {
  local targets=() r
  if [ "$K8S" = "ok" ]; then
    while IFS= read -r r; do [ -n "$r" ] && targets+=("-target=$r"); done < <(tf state list 2>/dev/null | grep 'kubectl_manifest\.' | grep -v 'kubectl_manifest.aws_load_balancer_controller')
    if [ ${#targets[@]} -gt 0 ]; then
      tf_destroy "Kubernetes manifests (Argo CD applications, Karpenter resources)" "${targets[@]}" || return 1
    fi
    graceful_k8s_services
  fi
  tf_destroy "EKS cluster and everything attached to module.eks" -target=module.eks || return 1
  tf_destroy "all remaining resources" || return 1
}

classify_failure() {   # prints: CREDS | LOCK | K8S | DEP | OTHER
  if   grep -qiE "ExpiredToken|security token.*(expired|invalid)|InvalidClientTokenId|Unable to locate credentials|SSO.*expired" "$LAST_OUT"; then echo CREDS
  elif grep -qi "Error acquiring the state lock" "$LAST_OUT"; then echo LOCK
  elif grep -qiE "provide credentials|Unauthorized|cluster unreachable|no configuration has been provided|connection refused|i/o timeout.*(eks|6443|443)|the server has asked" "$LAST_OUT"; then echo K8S
  elif grep -qiE "DependencyViolation|has dependent objects|resource sg-.*in use|currently in use|has a dependent object" "$LAST_OUT"; then echo DEP
  else echo OTHER; fi
}

aws_delete_cluster() {   # last resort: delete node groups, Fargate profiles and the cluster with the AWS CLI
  local ng fp
  terminate_instances
  for ng in $(awsw eks list-nodegroups --cluster-name "$NAME" --query 'nodegroups[]' --output text 2>/dev/null); do
    echo "Deleting node group $ng..."; awsw eks delete-nodegroup --cluster-name "$NAME" --nodegroup-name "$ng" >/dev/null
    awsw eks wait nodegroup-deleted --cluster-name "$NAME" --nodegroup-name "$ng"
  done
  for fp in $(awsw eks list-fargate-profiles --cluster-name "$NAME" --query 'fargateProfileNames[]' --output text 2>/dev/null); do
    echo "Deleting Fargate profile $fp..."; awsw eks delete-fargate-profile --cluster-name "$NAME" --fargate-profile-name "$fp" >/dev/null
    awsw eks wait fargate-profile-deleted --cluster-name "$NAME" --fargate-profile-name "$fp"
  done
  echo "Deleting EKS cluster $NAME..."
  awsw eks delete-cluster --name "$NAME" >/dev/null && awsw eks wait cluster-deleted --name "$NAME"
}

DESTROY_OK=true
if [ "$(state_count)" -gt 0 ]; then
  log "Preparing Terraform working directory"
  prepare_local
  tf init -input=false >/dev/null 2>&1 || echo "WARNING: terraform init reported problems; continuing"

  log "Cluster and Kubernetes access"
  refresh_k8s_state
  case "$K8S" in
    ok)     graceful_k8s_steps ;;
    gone)   echo "The cluster does not exist (deleted by hand?)."; drop_in_cluster_state ;;
    broken) [ "$CL_STATUS" != "UNKNOWN" ] && diagnose_k8s_access
            echo "Continuing without Kubernetes access: Helm and Kubernetes resources disappear with the cluster."
            drop_in_cluster_state ;;
  esac

  handle_tpcds_bucket || { echo "Stopping: fix the bucket problem above and re-run."; exit 1; }

  attempt=1
  while [ "$(state_count)" -gt 0 ] && [ "$attempt" -le 3 ]; do
    log "terraform destroy, attempt $attempt of 3"
    need_creds || { DESTROY_OK=false; break; }
    destroy_all
    [ "$(state_count)" -eq 0 ] && break
    case "$(classify_failure)" in
      CREDS) echo "AWS credentials expired during the run. Log in again and re-run ./cleanup.sh."; DESTROY_OK=false; break ;;
      LOCK)  die "Terraform state is locked (see the message above). If no other run is active: terraform -chdir=$LOCAL_DIR force-unlock <LOCK_ID>" ;;
      K8S)   echo "Kubernetes API is not usable; dropping in-cluster resources from the state and retrying."
             K8S="broken"; drop_in_cluster_state ;;
      DEP)   echo "A dependency is still released by AWS (ENIs, security groups). Waiting 90s and retrying."; sleep 90 ;;
      *)     echo "Unrecognized failure; retrying in 30s."; sleep 30 ;;
    esac
    attempt=$((attempt + 1))
  done

  if [ "$(state_count)" -gt 0 ] && [ "$DESTROY_OK" = true ]; then
    log "Terraform could not finish ($(state_count) resources left)"
    CL_STATUS=$(cluster_status)
    if [ "$CL_STATUS" != "NOT_FOUND" ] && confirm "Delete node groups and the EKS cluster '$NAME' with the AWS CLI, then let Terraform remove the rest?"; then
      aws_delete_cluster
      drop_in_cluster_state
      K8S="gone"
      tf_destroy "all remaining resources (after AWS CLI deletion)"
    elif [ "$CL_STATUS" = "NOT_FOUND" ]; then
      drop_in_cluster_state
      tf_destroy "all remaining resources"
    fi
  fi
else
  echo "Terraform state is empty; skipping terraform destroy."
fi
[ "$(state_count)" -eq 0 ] || DESTROY_OK=false

#---------------------------------------------------------------
# 3. sweep leftovers tagged for this deployment
#---------------------------------------------------------------
log "Looking for leftovers of '$NAME' in $AWS_REGION"
if ! need_creds; then
  echo "Skipping the sweep."
else
  report_leftovers
  INSTANCES=$(find_instances); LBS=$(find_lbs); OWN_EPS=$(find_own_endpoints); VOLUMES=$(find_volumes)
  LG=$(find_log_group); ROLE=$(find_node_role); KALIAS=$(find_kms_alias)
  # Only when Terraform no longer owns anything: orphans of an interrupted or failed run
  ORPHAN_CLUSTER=""; [ "$(state_count)" -eq 0 ] && [ "$(cluster_status)" != "NOT_FOUND" ] && ORPHAN_CLUSTER="$NAME"
  [ "$(state_count)" -gt 0 ] && { ROLE=""; KALIAS=""; }   # still managed by Terraform

  if [ -n "$INSTANCES$LBS$OWN_EPS$VOLUMES$LG$ROLE$KALIAS$ORPHAN_CLUSTER" ]; then
    if confirm "Delete these leftovers? (the VPC and its subnets/routes/gateways are NOT touched)"; then
      [ -n "$ORPHAN_CLUSTER" ] && aws_delete_cluster
      for arn in $LBS; do
        echo "Deleting load balancer $arn"
        case "$arn" in
          *loadbalancer/app/*|*loadbalancer/net/*|*loadbalancer/gwy/*) awsw elbv2 delete-load-balancer --load-balancer-arn "$arn" ;;
          *) awsw elb delete-load-balancer --load-balancer-name "${arn##*/}" ;;
        esac
      done
      terminate_instances
      if [ -n "$OWN_EPS" ]; then
        echo "Deleting this deployment's VPC endpoints: $(echo $OWN_EPS)"
        awsw ec2 delete-vpc-endpoints --vpc-endpoint-ids $OWN_EPS >/dev/null
        sleep 30
      fi
      for v in $VOLUMES; do echo "Deleting EBS volume $v"; awsw ec2 delete-volume --volume-id "$v"; done
      [ -n "$LG" ] && { echo "Deleting log group $LG"; awsw logs delete-log-group --log-group-name "$LG"; }
      [ -n "$KALIAS" ] && { echo "Deleting KMS alias $KMS_ALIAS (the key itself stays; it is scheduled for deletion by Terraform)"; awsw kms delete-alias --alias-name "$KMS_ALIAS"; }
      if [ -n "$ROLE" ]; then
        echo "Deleting IAM role $NODE_ROLE"
        for p in $(aws iam list-attached-role-policies --role-name "$NODE_ROLE" --query 'AttachedPolicies[].PolicyArn' --output text); do aws iam detach-role-policy --role-name "$NODE_ROLE" --policy-arn "$p"; done
        for p in $(aws iam list-role-policies --role-name "$NODE_ROLE" --query 'PolicyNames[]' --output text); do aws iam delete-role-policy --role-name "$NODE_ROLE" --policy-name "$p"; done
        for ip in $(aws iam list-instance-profiles-for-role --role-name "$NODE_ROLE" --query 'InstanceProfiles[].InstanceProfileName' --output text); do
          aws iam remove-role-from-instance-profile --instance-profile-name "$ip" --role-name "$NODE_ROLE"; aws iam delete-instance-profile --instance-profile-name "$ip"; done
        aws iam delete-role --role-name "$NODE_ROLE"
      fi
    else
      echo "Leftovers kept."
    fi
  fi

  # ENIs tagged by the VPC CNI for this cluster: they detach some time after the nodes are gone
  for attempt in 1 2 3 4 5 6; do
    ENIS=$(find_enis); [ -z "$ENIS" ] && break
    while read -r eni st; do
      [ -z "$eni" ] && continue
      if [ "$st" = "available" ]; then echo "Deleting unused network interface $eni"; awsw ec2 delete-network-interface --network-interface-id "$eni" 2>&1 | sed 's/^/  /'
      else echo "Network interface $eni is $st; waiting for it to detach"; fi
    done <<<"$ENIS"
    [ "$attempt" -lt 6 ] && sleep 50
  done

  # Security groups: released only after the cluster (control-plane ENIs) and endpoints are gone
  SGS=$(find_own_sgs)
  if [ -n "$SGS" ] && [ "$(state_count)" -eq 0 ]; then
    echo "Security groups of this deployment still present: $(echo $SGS)"
    if confirm "Delete them?"; then
      for sg in $SGS; do
        for try in $(seq 1 15); do
          awsw ec2 delete-security-group --group-id "$sg" >/dev/null 2>&1 && { echo "  deleted $sg"; break; }
          [ "$try" -lt 15 ] && sleep 20 || echo "  could not delete $sg (still in use; re-run ./cleanup.sh in a few minutes)"
        done
      done
    fi
  elif [ -n "$SGS" ]; then
    echo "Security groups still present (they go with the cluster): $(echo $SGS)"
  fi
fi

#---------------------------------------------------------------
# 4. result
#---------------------------------------------------------------
rm -f "$KCFG" "$LAST_OUT"
REMAINING_SGS=$(find_own_sgs 2>/dev/null)
if [ "$(state_count)" -eq 0 ] && [ "$DESTROY_OK" = true ]; then
  echo "Removing local deployment files..."
  rm -f "$PARAMS_FILE" kubeconfig.yaml "$TF_DIR/terraform.tfstate.bak" "$LOCAL_DIR/terraform.tfstate" "$LOCAL_DIR/terraform.tfstate.backup"
  if [ -n "$REMAINING_SGS" ]; then
    echo "Done, except security groups still in use: $(echo $REMAINING_SGS). They are released shortly after the cluster's network interfaces; run ./cleanup.sh again later."
    exit 1
  fi
  [ -n "$TPCDS_KEPT" ] && echo "Kept (with its data): s3://$TPCDS_KEPT. The next ./deploy.sh adopts it. To delete it and all its data instead: aws s3 rb s3://$TPCDS_KEPT --force"
  echo "Clean. The existing VPC, subnets and route tables were not modified. Run ./deploy.sh for a fresh deployment."
  exit 0
fi
echo "Cleanup is NOT complete (Terraform state resources: $(state_count)). Read the messages above; ./cleanup.sh is safe to run again."
echo "Full log: $LOG"
exit 1

# Exit inside the block, so nothing appended to the file during a run is ever executed.
exit
}
