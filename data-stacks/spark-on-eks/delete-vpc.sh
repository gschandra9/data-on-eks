#!/usr/bin/env bash
# Delete the VPC created by create-vpc.sh, and everything inside it
# (NAT gateways + EIPs, endpoints, IGW, egress-only IGW, subnets, route tables, SGs).
#
# Usage:
#   ./delete-vpc.sh                          # find VPC by Name tag (VPC_NAME)
#   VPC_ID=vpc-0abc... ./delete-vpc.sh       # target a specific VPC
#   VPC_NAME=fs-spark-on-eks ./delete-vpc.sh
#   FORCE=true ./delete-vpc.sh               # skip the confirmation prompt
#
# Run the stack's cleanup.sh (terraform destroy) first if EKS was deployed into this VPC.
set -euo pipefail
REGION="${REGION:-us-west-2}"
PREFIX="${PREFIX-fs-}"
VPC_NAME="${VPC_NAME:-${PREFIX}spark-on-eks}"
VPC_ID="${VPC_ID:-}"
FORCE="${FORCE:-false}"

ec2() { aws ec2 "$@" --region "$REGION"; }

# ---------- Resolve target VPC(s) ----------
if [ -n "$VPC_ID" ]; then
  TARGETS=$(ec2 describe-vpcs --vpc-ids "$VPC_ID" --query "Vpcs[].VpcId" --output text)
else
  TARGETS=$(ec2 describe-vpcs --filters "Name=tag:Name,Values=$VPC_NAME" --query "Vpcs[].VpcId" --output text)
fi
if [ -z "$TARGETS" ]; then
  echo "No VPC found (region=$REGION, name=${VPC_NAME}, id=${VPC_ID:-n/a}). Nothing to do."
  exit 0
fi

echo "Account: $(aws sts get-caller-identity --query Account --output text)   Region: $REGION"
echo "VPC(s) to delete: $TARGETS"

# ---------- Safety checks: refuse if workloads are still running ----------
for V in $TARGETS; do
  INSTANCES=$(ec2 describe-instances \
    --filters "Name=vpc-id,Values=$V" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query "Reservations[].Instances[].InstanceId" --output text)
  LBS=$(aws elbv2 describe-load-balancers --region "$REGION" \
    --query "LoadBalancers[?VpcId=='$V'].LoadBalancerArn" --output text 2>/dev/null || true)
  if [ -n "$INSTANCES" ] || [ -n "$LBS" ]; then
    echo "ERROR: $V still has running resources. Delete them first (e.g. run cleanup.sh / terraform destroy)."
    [ -n "$INSTANCES" ] && echo "  EC2 instances: $INSTANCES"
    [ -n "$LBS" ] && echo "  Load balancers: $LBS"
    exit 1
  fi
done

if [ "$FORCE" != "true" ]; then
  read -r -p "Delete the VPC(s) above and everything inside? [y/N] " ans
  [[ "$ans" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 1; }
fi

cleanup_vpc() {
  local V=$1
  echo "Cleaning up $V ..."

  # NAT gateways (+ their EIPs)
  local NATS EIPS
  NATS=$(ec2 describe-nat-gateways --filter "Name=vpc-id,Values=$V" "Name=state,Values=pending,available" \
    --query "NatGateways[].NatGatewayId" --output text)
  EIPS=$(ec2 describe-nat-gateways --filter "Name=vpc-id,Values=$V" \
    --query "NatGateways[].NatGatewayAddresses[].AllocationId" --output text)
  for n in $NATS; do ec2 delete-nat-gateway --nat-gateway-id "$n" >/dev/null; echo "  deleting NAT $n"; done
  if [ -n "$NATS" ]; then ec2 wait nat-gateway-deleted --nat-gateway-ids $NATS; fi
  for e in $(echo "$EIPS" | tr -s ' \t' '\n' | sort -u); do
    [ -z "$e" ] || [ "$e" = "None" ] && continue
    if ec2 release-address --allocation-id "$e" 2>/dev/null; then echo "  released EIP $e"; fi
  done

  # VPC endpoints
  local EPS
  EPS=$(ec2 describe-vpc-endpoints --filters "Name=vpc-id,Values=$V" \
    --query "VpcEndpoints[?State!='deleted'].VpcEndpointId" --output text)
  if [ -n "$EPS" ]; then
    ec2 delete-vpc-endpoints --vpc-endpoint-ids $EPS >/dev/null && echo "  deleted endpoints $EPS"
    # endpoint ENIs disappear asynchronously
    for i in {1..30}; do
      LEFT=$(ec2 describe-vpc-endpoints --filters "Name=vpc-id,Values=$V" \
        --query "length(VpcEndpoints[?State!='deleted'])" --output text)
      [ "$LEFT" = "0" ] && break
      sleep 5
    done
  fi

  # Internet gateways
  for g in $(ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$V" \
      --query "InternetGateways[].InternetGatewayId" --output text); do
    ec2 detach-internet-gateway --internet-gateway-id "$g" --vpc-id "$V"
    ec2 delete-internet-gateway --internet-gateway-id "$g"; echo "  deleted IGW $g"
  done

  # Egress-only IGWs
  for g in $(ec2 describe-egress-only-internet-gateways \
      --query "EgressOnlyInternetGateways[?Attachments[?VpcId=='$V']].EgressOnlyInternetGatewayId" --output text); do
    ec2 delete-egress-only-internet-gateway --egress-only-internet-gateway-id "$g" >/dev/null; echo "  deleted EIGW $g"
  done

  # Leftover detached ENIs
  for eni in $(ec2 describe-network-interfaces --filters "Name=vpc-id,Values=$V" "Name=status,Values=available" \
      --query "NetworkInterfaces[].NetworkInterfaceId" --output text); do
    ec2 delete-network-interface --network-interface-id "$eni"; echo "  deleted ENI $eni"
  done

  # Subnets
  for s in $(ec2 describe-subnets --filters "Name=vpc-id,Values=$V" --query "Subnets[].SubnetId" --output text); do
    ec2 delete-subnet --subnet-id "$s"; echo "  deleted subnet $s"
  done

  # Non-main route tables
  for rt in $(ec2 describe-route-tables --filters "Name=vpc-id,Values=$V" \
      --query "RouteTables[?!(Associations[?Main==\`true\`])].RouteTableId" --output text); do
    ec2 delete-route-table --route-table-id "$rt"; echo "  deleted route table $rt"
  done

  # Non-default security groups (retry: SGs can reference each other)
  for pass in 1 2 3; do
    local SGS
    SGS=$(ec2 describe-security-groups --filters "Name=vpc-id,Values=$V" \
      --query "SecurityGroups[?GroupName!='default'].GroupId" --output text)
    [ -z "$SGS" ] && break
    for sg in $SGS; do
      if ec2 delete-security-group --group-id "$sg" 2>/dev/null; then echo "  deleted SG $sg"; fi
    done
  done

  ec2 delete-vpc --vpc-id "$V"
  echo "  deleted VPC $V"
}

for v in $TARGETS; do cleanup_vpc "$v"; done
echo "Done."
