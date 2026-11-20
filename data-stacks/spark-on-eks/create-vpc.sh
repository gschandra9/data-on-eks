#!/usr/bin/env bash
# Creates the VPC layout for the spark-on-eks stack; every resource name starts with PREFIX (default "fs-").
# Override with: PREFIX=abc- ./create-vpc.sh   (use the same PREFIX for deploy.sh). IPv6 /64s are derived from the Amazon-assigned /56.
# Deletes any existing VPC with the same Name tag first, then create a new one.
set -euo pipefail

REGION=us-west-2
PREFIX="fs-"              # prefix for all resource names; must match the prefix used by deploy.sh
BASE_NAME=spark-on-eks
VPC_NAME="${PREFIX}${BASE_NAME}"
PRIMARY_CIDR=10.0.0.0/16
SECONDARY_CIDRS=(100.64.0.0/16 100.65.0.0/16 100.66.0.0/16)
FORCE="${FORCE:-false}"   # FORCE=true skips the delete confirmation

# identifier | name | az | ipv4 cidr | ipv6 /64 index (hex, 00-ff) | type
SUBNETS=(
  "public-subnet-1|${VPC_NAME}-public-us-west-2a|us-west-2a|10.0.48.0/24|00|public"
  "public-subnet-2|${VPC_NAME}-public-us-west-2b|us-west-2b|10.0.49.0/24|01|public"
  "public-subnet-3|${VPC_NAME}-public-us-west-2c|us-west-2c|10.0.50.0/24|02|public"
  "private-subnet-1|${VPC_NAME}-private-us-west-2a|us-west-2a|10.0.0.0/20|03|private"
  "private-subnet-2|${VPC_NAME}-private-us-west-2b|us-west-2b|10.0.16.0/20|04|private"
  "private-subnet-3|${VPC_NAME}-private-us-west-2c|us-west-2c|10.0.32.0/20|05|private"
  "private-subnet-4|${VPC_NAME}-private-secondary1-us-west-2a|us-west-2a|100.64.0.0/16|06|private"
  "private-subnet-5|${VPC_NAME}-private-secondary1-us-west-2b|us-west-2b|100.65.0.0/16|07|private"
  "private-subnet-6|${VPC_NAME}-private-secondary1-us-west-2c|us-west-2c|100.66.0.0/16|08|private"
)

ec2() { aws ec2 "$@" --region "$REGION"; }
tag() { ec2 create-tags --resources "$1" --tags "Key=Name,Value=$2"; }

# ---------- 0. Clean up existing VPC(s) with the same name ----------
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
  [ -n "$NATS" ] && ec2 wait nat-gateway-deleted --nat-gateway-ids $NATS

  # EIPs: from NATs + any tagged for this VPC
  EIPS="$EIPS $(ec2 describe-addresses --filters "Name=tag:Name,Values=$VPC_NAME-nat-eip" \
    --query "Addresses[].AllocationId" --output text)"
  for e in $(echo $EIPS | tr ' ' '\n' | sort -u); do
    ec2 release-address --allocation-id "$e" 2>/dev/null && echo "  released EIP $e" || true
  done

  # VPC endpoints
  local EPS
  EPS=$(ec2 describe-vpc-endpoints --filters "Name=vpc-id,Values=$V" --query "VpcEndpoints[].VpcEndpointId" --output text)
  [ -n "$EPS" ] && ec2 delete-vpc-endpoints --vpc-endpoint-ids $EPS >/dev/null && echo "  deleted endpoints"

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

  # Leftover detached ENIs (e.g. from EKS/Lambda)
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

  # Non-default security groups
  for sg in $(ec2 describe-security-groups --filters "Name=vpc-id,Values=$V" \
      --query "SecurityGroups[?GroupName!='default'].GroupId" --output text); do
    ec2 delete-security-group --group-id "$sg"; echo "  deleted SG $sg"
  done

  ec2 delete-vpc --vpc-id "$V"
  echo "  deleted VPC $V"
}

EXISTING=$(ec2 describe-vpcs --filters "Name=tag:Name,Values=$VPC_NAME" --query "Vpcs[].VpcId" --output text)
if [ -n "$EXISTING" ]; then
  echo "Found existing VPC(s) named $VPC_NAME: $EXISTING"
  if [ "$FORCE" != "true" ]; then
    read -r -p "Delete them and everything inside? [y/N] " ans
    [[ "$ans" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 1; }
  fi
  for v in $EXISTING; do cleanup_vpc "$v"; done
fi

# ---------- 1. VPC + Amazon-provided IPv6 /56 ----------
VPC_ID=$(ec2 create-vpc --cidr-block "$PRIMARY_CIDR" --amazon-provided-ipv6-cidr-block \
  --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=$VPC_NAME}]" \
  --query Vpc.VpcId --output text)
echo "VPC: $VPC_ID"
ec2 wait vpc-available --vpc-ids "$VPC_ID"
ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-hostnames '{"Value":true}'
ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-support   '{"Value":true}'

# ---------- 2. Secondary IPv4 CIDRs ----------
for c in "${SECONDARY_CIDRS[@]}"; do
  ec2 associate-vpc-cidr-block --vpc-id "$VPC_ID" --cidr-block "$c" >/dev/null
  echo "Associated secondary CIDR $c"
done

# Wait for all IPv4 + IPv6 associations (JMESPath has no '+', so add in bash)
for i in {1..30}; do
  P4=$(ec2 describe-vpcs --vpc-ids "$VPC_ID" \
    --query "length(Vpcs[0].CidrBlockAssociationSet[?CidrBlockState.State!='associated'])" --output text)
  P6=$(ec2 describe-vpcs --vpc-ids "$VPC_ID" \
    --query "length(Vpcs[0].Ipv6CidrBlockAssociationSet[?Ipv6CidrBlockState.State!='associated'])" --output text)
  [ $((P4 + P6)) -eq 0 ] && break
  sleep 2
done

# ---------- 3. Derive IPv6 base from assigned /56 ----------
V6_56=$(ec2 describe-vpcs --vpc-ids "$VPC_ID" \
  --query "Vpcs[0].Ipv6CidrBlockAssociationSet[0].Ipv6CidrBlock" --output text)
if [ -z "$V6_56" ] || [ "$V6_56" = "None" ]; then echo "ERROR: no IPv6 /56 on VPC"; exit 1; fi
P=${V6_56%%/56}; P=${P%::}
IFS=: read -r h1 h2 h3 h4 <<< "$P"
h4=$(printf "%04x" "0x${h4:-0}")
V6_BASE="${h1}:${h2}:${h3:-0}:${h4:0:2}"
echo "IPv6 /56: $V6_56  ->  subnet base ${V6_BASE}XX::/64"

# ---------- 4. Gateways ----------
IGW_ID=$(ec2 create-internet-gateway \
  --tag-specifications "ResourceType=internet-gateway,Tags=[{Key=Name,Value=$VPC_NAME-igw}]" \
  --query InternetGateway.InternetGatewayId --output text)
ec2 attach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID"

EIGW_ID=$(ec2 create-egress-only-internet-gateway --vpc-id "$VPC_ID" \
  --tag-specifications "ResourceType=egress-only-internet-gateway,Tags=[{Key=Name,Value=$VPC_NAME-eigw}]" \
  --query EgressOnlyInternetGateway.EgressOnlyInternetGatewayId --output text)

# ---------- 5. Route tables ----------
PUB_RT=$(ec2 create-route-table --vpc-id "$VPC_ID" --query RouteTable.RouteTableId --output text)
tag "$PUB_RT" "$VPC_NAME-public-rt"
ec2 create-route --route-table-id "$PUB_RT" --destination-cidr-block 0.0.0.0/0 --gateway-id "$IGW_ID" >/dev/null
ec2 create-route --route-table-id "$PUB_RT" --destination-ipv6-cidr-block ::/0 --gateway-id "$IGW_ID" >/dev/null

PRIV_RT=$(ec2 create-route-table --vpc-id "$VPC_ID" --query RouteTable.RouteTableId --output text)
tag "$PRIV_RT" "$VPC_NAME-private-rt"
ec2 create-route --route-table-id "$PRIV_RT" --destination-ipv6-cidr-block ::/0 \
  --egress-only-internet-gateway-id "$EIGW_ID" >/dev/null

# ---------- 6. Subnets ----------
PUBLIC_SUBNET_1=""
for entry in "${SUBNETS[@]}"; do
  IFS='|' read -r ID_LABEL NAME AZ CIDR IDX TYPE <<< "$entry"
  V6="${V6_BASE}${IDX}::/64"

  if [ "$TYPE" = "public" ]; then ROLE_TAG="{Key=kubernetes.io/role/elb,Value=1}"
  else ROLE_TAG="{Key=kubernetes.io/role/internal-elb,Value=1}"; fi

  SID=$(ec2 create-subnet --vpc-id "$VPC_ID" --availability-zone "$AZ" \
    --cidr-block "$CIDR" --ipv6-cidr-block "$V6" \
    --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=$NAME},{Key=Identifier,Value=$ID_LABEL},$ROLE_TAG]" \
    --query Subnet.SubnetId --output text)

  ec2 modify-subnet-attribute --subnet-id "$SID" --assign-ipv6-address-on-creation
  ec2 modify-subnet-attribute --subnet-id "$SID" --no-map-public-ip-on-launch

  if [ "$TYPE" = "public" ]; then
    ec2 associate-route-table --route-table-id "$PUB_RT" --subnet-id "$SID" >/dev/null
    [ -z "$PUBLIC_SUBNET_1" ] && PUBLIC_SUBNET_1=$SID
  else
    ec2 associate-route-table --route-table-id "$PRIV_RT" --subnet-id "$SID" >/dev/null
  fi
  printf "%-17s %-45s %-25s %-15s %s\n" "$ID_LABEL" "$NAME" "$SID" "$CIDR" "$V6"
done

# ---------- 7. NAT Gateway (single, in public-subnet-1) ----------
EIP=$(ec2 allocate-address --domain vpc \
  --tag-specifications "ResourceType=elastic-ip,Tags=[{Key=Name,Value=$VPC_NAME-nat-eip}]" \
  --query AllocationId --output text)
NAT_ID=$(ec2 create-nat-gateway --subnet-id "$PUBLIC_SUBNET_1" --allocation-id "$EIP" \
  --tag-specifications "ResourceType=natgateway,Tags=[{Key=Name,Value=$VPC_NAME-nat}]" \
  --query NatGateway.NatGatewayId --output text)
echo "Waiting for NAT Gateway $NAT_ID ..."
ec2 wait nat-gateway-available --nat-gateway-ids "$NAT_ID"
ec2 create-route --route-table-id "$PRIV_RT" --destination-cidr-block 0.0.0.0/0 --nat-gateway-id "$NAT_ID" >/dev/null

# ---------- 8. Summary ----------
echo "Done. VPC=$VPC_ID IGW=$IGW_ID EIGW=$EIGW_ID NAT=$NAT_ID"
ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" \
  --query "sort_by(Subnets,&Tags[?Key=='Identifier']|[0].Value)[].{Id:Tags[?Key=='Identifier']|[0].Value,Name:Tags[?Key=='Name']|[0].Value,SubnetId:SubnetId,AZ:AvailabilityZone,CIDR:CidrBlock,IPv6:Ipv6CidrBlockAssociationSet[0].Ipv6CidrBlock,AutoIPv6:AssignIpv6AddressOnCreation,Public:MapPublicIpOnLaunch}" \
  --output table
