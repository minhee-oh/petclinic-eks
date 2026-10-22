#!/bin/bash
# A. 네트워크 — VPC · 서브넷 6개(퍼블릭/앱/DB × 2AZ) · IGW · NAT 1개 · 라우팅 3개
# NAT 는 비용 때문에 2a 에 1개만 둔다 (강사 예시는 AZ별 2개)
set -euo pipefail
source "$(dirname "$0")/../env.sh"

TAG='{Key=Project,Value=petclinic}'

VPC_ID=$(aws ec2 create-vpc --cidr-block 10.0.0.0/16 \
  --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=pc-vpc},$TAG]" \
  --query Vpc.VpcId --output text); save VPC_ID
aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-support
aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-hostnames

mk_subnet() {  # 이름 CIDR AZ 추가태그
  aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block $2 --availability-zone $3 \
    --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=$1},$TAG$4]" \
    --query Subnet.SubnetId --output text
}
ELB=',{Key=kubernetes.io/role/elb,Value=1}'            # 인터넷 ALB 는 여기에
APP=',{Key=kubernetes.io/role/internal-elb,Value=1}'   # 노드 · Pod

SUBNET_PUB_A=$(mk_subnet pc-subnet-pub-a 10.0.0.0/24   ap-northeast-2a "$ELB"); save SUBNET_PUB_A
SUBNET_PUB_C=$(mk_subnet pc-subnet-pub-c 10.0.1.0/24   ap-northeast-2c "$ELB"); save SUBNET_PUB_C
SUBNET_APP_A=$(mk_subnet pc-subnet-app-a 10.0.16.0/20  ap-northeast-2a "$APP"); save SUBNET_APP_A
SUBNET_APP_C=$(mk_subnet pc-subnet-app-c 10.0.32.0/20  ap-northeast-2c "$APP"); save SUBNET_APP_C
SUBNET_DB_A=$(mk_subnet  pc-subnet-db-a  10.0.100.0/24 ap-northeast-2a "");     save SUBNET_DB_A
SUBNET_DB_C=$(mk_subnet  pc-subnet-db-c  10.0.101.0/24 ap-northeast-2c "");     save SUBNET_DB_C

aws ec2 modify-subnet-attribute --subnet-id $SUBNET_PUB_A --map-public-ip-on-launch
aws ec2 modify-subnet-attribute --subnet-id $SUBNET_PUB_C --map-public-ip-on-launch

# IGW · 퍼블릭 라우팅
IGW_ID=$(aws ec2 create-internet-gateway \
  --tag-specifications "ResourceType=internet-gateway,Tags=[{Key=Name,Value=pc-igw},$TAG]" \
  --query InternetGateway.InternetGatewayId --output text); save IGW_ID
aws ec2 attach-internet-gateway --internet-gateway-id $IGW_ID --vpc-id $VPC_ID

mk_rtb() {
  aws ec2 create-route-table --vpc-id $VPC_ID \
    --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=$1},$TAG]" \
    --query RouteTable.RouteTableId --output text
}
RTB_PUB=$(mk_rtb pc-rtb-pub); save RTB_PUB
aws ec2 create-route --route-table-id $RTB_PUB --destination-cidr-block 0.0.0.0/0 --gateway-id $IGW_ID >/dev/null
aws ec2 associate-route-table --route-table-id $RTB_PUB --subnet-id $SUBNET_PUB_A >/dev/null
aws ec2 associate-route-table --route-table-id $RTB_PUB --subnet-id $SUBNET_PUB_C >/dev/null

# NAT (2a) · 앱 라우팅
EIP_NAT=$(aws ec2 allocate-address --domain vpc \
  --tag-specifications "ResourceType=elastic-ip,Tags=[{Key=Name,Value=pc-eip-nat-a},$TAG]" \
  --query AllocationId --output text); save EIP_NAT
NAT_ID=$(aws ec2 create-nat-gateway --subnet-id $SUBNET_PUB_A --allocation-id $EIP_NAT \
  --tag-specifications "ResourceType=natgateway,Tags=[{Key=Name,Value=pc-nat-a},$TAG]" \
  --query NatGateway.NatGatewayId --output text); save NAT_ID
echo "NAT 생성 대기 (1~2분)..."
aws ec2 wait nat-gateway-available --nat-gateway-ids $NAT_ID

RTB_APP=$(mk_rtb pc-rtb-app); save RTB_APP
aws ec2 create-route --route-table-id $RTB_APP --destination-cidr-block 0.0.0.0/0 --nat-gateway-id $NAT_ID >/dev/null
aws ec2 associate-route-table --route-table-id $RTB_APP --subnet-id $SUBNET_APP_A >/dev/null
aws ec2 associate-route-table --route-table-id $RTB_APP --subnet-id $SUBNET_APP_C >/dev/null

# DB 라우팅 — 인터넷 경로 없음 (local only)
RTB_DB=$(mk_rtb pc-rtb-db); save RTB_DB
aws ec2 associate-route-table --route-table-id $RTB_DB --subnet-id $SUBNET_DB_A >/dev/null
aws ec2 associate-route-table --route-table-id $RTB_DB --subnet-id $SUBNET_DB_C >/dev/null

aws ec2 describe-subnets --filters Name=vpc-id,Values=$VPC_ID \
  --query 'Subnets[].[Tags[?Key==`Name`]|[0].Value,CidrBlock,AvailabilityZone]' --output table
