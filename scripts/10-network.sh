#!/bin/bash
# 네트워크 — VPC · 서브넷 8개(public/app/db/mgmt × AZ 2) · IGW · NAT 2개(AZ마다) · 라우트 테이블 6개 · S3 엔드포인트 · SG 3개
# 기획서 2.1. 이름 태그로 먼저 찾으므로 다시 실행해도 같은 자원을 또 만들지 않는다.
set -euo pipefail
source "$(dirname "$0")/../env.sh"
require_aws 20

# ── VPC ─────────────────────────────────────────────
VPC_ID=$(ec2_id vpc pc-vpc)
if [ -z "$VPC_ID" ]; then
  VPC_ID=$(aws ec2 create-vpc --cidr-block $VPC_CIDR --tag-specifications "$(tagspec vpc pc-vpc)" \
    --query Vpc.VpcId --output text)
fi
save VPC_ID
# ALB·RDS 엔드포인트 이름 해석과 EKS 프라이빗 엔드포인트에 둘 다 필요
aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-support
aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-hostnames

# ── 서브넷 ──────────────────────────────────────────
ensure_subnet() {  # 변수명 이름 CIDR AZ [추가 태그]
  local id; id=$(ec2_id subnet $2)
  if [ -z "$id" ]; then
    id=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block $3 --availability-zone $4 \
      --tag-specifications "$(tagspec subnet $2 "${5:-}")" --query Subnet.SubnetId --output text)
  fi
  printf -v "$1" %s "$id"; save "$1"
}
ELB=',{Key=kubernetes.io/role/elb,Value=1}'   # LBC 가 인터넷 ALB 를 둘 서브넷을 찾는 태그
ensure_subnet SUBNET_PUB_A  pc-subnet-pub-a  $CIDR_PUB_A  $AZ_A "$ELB"
ensure_subnet SUBNET_PUB_C  pc-subnet-pub-c  $CIDR_PUB_C  $AZ_C "$ELB"
ensure_subnet SUBNET_APP_A  pc-subnet-app-a  $CIDR_APP_A  $AZ_A
ensure_subnet SUBNET_APP_C  pc-subnet-app-c  $CIDR_APP_C  $AZ_C
ensure_subnet SUBNET_DB_A   pc-subnet-db-a   $CIDR_DB_A   $AZ_A
ensure_subnet SUBNET_DB_C   pc-subnet-db-c   $CIDR_DB_C   $AZ_C
ensure_subnet SUBNET_MGMT_A pc-subnet-mgmt-a $CIDR_MGMT_A $AZ_A
ensure_subnet SUBNET_MGMT_C pc-subnet-mgmt-c $CIDR_MGMT_C $AZ_C
# 퍼블릭 서브넷이라도 자동 공인 IP 는 켜지 않는다 — 여기 둘 EC2 가 없고, ALB·NAT 는 스스로 주소를 가진다

# ── IGW ─────────────────────────────────────────────
IGW_ID=$(ec2_id igw pc-igw)
if [ -z "$IGW_ID" ]; then
  IGW_ID=$(aws ec2 create-internet-gateway --tag-specifications "$(tagspec internet-gateway pc-igw)" \
    --query InternetGateway.InternetGatewayId --output text)
fi
save IGW_ID
attached=$(aws ec2 describe-internet-gateways --internet-gateway-ids $IGW_ID \
  --query 'InternetGateways[0].Attachments[0].VpcId' --output text)
[ "$attached" = "$VPC_ID" ] || aws ec2 attach-internet-gateway --internet-gateway-id $IGW_ID --vpc-id $VPC_ID

# ── NAT (AZ마다 1개 — AZ 하나가 죽어도 다른 AZ 의 노드는 계속 밖으로 나간다) ──
ensure_nat() {  # 변수명 AZ접미사 퍼블릭서브넷
  local eip nat
  eip=$(ec2_id eip pc-eip-nat-$2)
  [ -n "$eip" ] || eip=$(aws ec2 allocate-address --domain vpc \
    --tag-specifications "$(tagspec elastic-ip pc-eip-nat-$2)" --query AllocationId --output text)
  nat=$(ec2_id nat pc-nat-$2)
  [ -n "$nat" ] || nat=$(aws ec2 create-nat-gateway --subnet-id $3 --allocation-id $eip \
    --tag-specifications "$(tagspec natgateway pc-nat-$2)" --query NatGateway.NatGatewayId --output text)
  printf -v "$1" %s "$nat"; save "$1"
}
ensure_nat NAT_A a $SUBNET_PUB_A
ensure_nat NAT_C c $SUBNET_PUB_C
log "NAT available 대기 (1~3분)"
aws ec2 wait nat-gateway-available --nat-gateway-ids $NAT_A $NAT_C

# ── 라우트 테이블 ───────────────────────────────────
ensure_rtb() {  # 변수명 이름
  local id; id=$(ec2_id rtb $2)
  [ -n "$id" ] || id=$(aws ec2 create-route-table --vpc-id $VPC_ID \
    --tag-specifications "$(tagspec route-table $2)" --query RouteTable.RouteTableId --output text)
  printf -v "$1" %s "$id"; save "$1"
}
default_route() {  # rtb --gateway-id|--nat-gateway-id 대상
  aws ec2 replace-route --route-table-id $1 --destination-cidr-block 0.0.0.0/0 $2 $3 2>/dev/null \
    || aws ec2 create-route --route-table-id $1 --destination-cidr-block 0.0.0.0/0 $2 $3 >/dev/null
}
assoc() {  # rtb subnet — 다른 테이블에 붙어 있으면 옮긴다
  local cur
  cur=$(aws ec2 describe-route-tables --filters Name=association.subnet-id,Values=$2 \
    --query "RouteTables[0].Associations[?SubnetId=='$2'].[RouteTableAssociationId,RouteTableId]" --output text)
  if [ -z "$cur" ] || [ "$cur" = "None" ]; then
    aws ec2 associate-route-table --route-table-id $1 --subnet-id $2 >/dev/null
  elif [ "$(echo "$cur" | cut -f2)" != "$1" ]; then
    aws ec2 replace-route-table-association --association-id "$(echo "$cur" | cut -f1)" --route-table-id $1 >/dev/null
  fi
}
ensure_rtb RTB_PUB    pc-rtb-pub
ensure_rtb RTB_APP_A  pc-rtb-app-a
ensure_rtb RTB_APP_C  pc-rtb-app-c
ensure_rtb RTB_MGMT_A pc-rtb-mgmt-a
ensure_rtb RTB_MGMT_C pc-rtb-mgmt-c
ensure_rtb RTB_DB     pc-rtb-db          # 기본 경로 없음 = 인터넷과 오갈 길이 없다

default_route $RTB_PUB    --gateway-id     $IGW_ID
default_route $RTB_APP_A  --nat-gateway-id $NAT_A
default_route $RTB_APP_C  --nat-gateway-id $NAT_C
default_route $RTB_MGMT_A --nat-gateway-id $NAT_A
default_route $RTB_MGMT_C --nat-gateway-id $NAT_C

assoc $RTB_PUB    $SUBNET_PUB_A;  assoc $RTB_PUB    $SUBNET_PUB_C
assoc $RTB_APP_A  $SUBNET_APP_A;  assoc $RTB_APP_C  $SUBNET_APP_C
assoc $RTB_MGMT_A $SUBNET_MGMT_A; assoc $RTB_MGMT_C $SUBNET_MGMT_C
assoc $RTB_DB     $SUBNET_DB_A;   assoc $RTB_DB     $SUBNET_DB_C

# ── S3 게이트웨이 엔드포인트 — ECR 이미지 레이어(S3)가 NAT 를 거치지 않게 ──
S3_SVC=com.amazonaws.$AWS_REGION.s3
VPCE_S3=$(aws ec2 describe-vpc-endpoints --filters Name=vpc-id,Values=$VPC_ID Name=service-name,Values=$S3_SVC \
  Name=vpc-endpoint-state,Values=available,pending --query 'VpcEndpoints[0].VpcEndpointId' --output text)
PRIV_RTBS="$RTB_APP_A $RTB_APP_C $RTB_MGMT_A $RTB_MGMT_C"
if [ "$VPCE_S3" = "None" ]; then
  VPCE_S3=$(aws ec2 create-vpc-endpoint --vpc-id $VPC_ID --vpc-endpoint-type Gateway --service-name $S3_SVC \
    --route-table-ids $PRIV_RTBS --tag-specifications "$(tagspec vpc-endpoint pc-vpce-s3)" \
    --query VpcEndpoint.VpcEndpointId --output text)
else
  aws ec2 modify-vpc-endpoint --vpc-endpoint-id $VPCE_S3 --add-route-table-ids $PRIV_RTBS >/dev/null
fi
save VPCE_S3

# ── 보안 그룹 — 격리는 서브넷이 아니라 여기서 한다 ─────────
ensure_sg() {  # 변수명 이름 설명
  local id; id=$(ec2_id sg $2)
  [ -n "$id" ] || id=$(aws ec2 create-security-group --vpc-id $VPC_ID --group-name $2 --description "$3" \
    --tag-specifications "$(tagspec security-group $2)" --query GroupId --output text)
  printf -v "$1" %s "$id"; save "$1"
}
ensure_sg SG_MGMT pc-sg-mgmt "SSM mgmt EC2 - no inbound"
ensure_sg SG_NODE pc-sg-node "EKS nodes - attached to nodegroup, source for RDS rule"
ensure_sg SG_RDS  pc-sg-rds  "RDS MySQL - 3306 from nodes and mgmt only"
allow_sg $SG_RDS 3306 $SG_NODE "nodes (was pods) to RDS"
allow_sg $SG_RDS 3306 $SG_MGMT "mgmt EC2 bootstrap.sql"
# 관리 EC2 → EKS API 443 은 클러스터가 생긴 뒤 30-cluster.sh 에서 연다 (클러스터 SG 가 그때 생김)

log "네트워크 완료 — VPC $VPC_ID"
