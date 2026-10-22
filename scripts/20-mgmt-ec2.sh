#!/bin/bash
# 관리 EC2 — private-mgmt-a, 퍼블릭 IP·키 페어 없음, 접속은 SSM 만
# 용도: EKS 프라이빗 엔드포인트로 가는 터널 경유지, 이미지 빌드·Trivy·푸시, bootstrap.sql 실행
set -euo pipefail
source "$(dirname "$0")/../env.sh"
require_aws 15

ROLE=pc-role-mgmt
PROFILE=pc-profile-mgmt

# ── IAM 역할·인스턴스 프로파일 ─────────────────────────
if ! aws iam get-role --role-name $ROLE >/dev/null 2>&1; then
  aws iam create-role --role-name $ROLE --tags $(tags_kv) \
    --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}' >/dev/null
fi
# SSM 접속 + ECR 푸시(빌드 담당). 비밀 읽기 권한은 3일차 50-secrets.sh 에서 해당 비밀 ARN 으로만 붙인다
aws iam attach-role-policy --role-name $ROLE --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
aws iam attach-role-policy --role-name $ROLE --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPowerUser
aws iam put-role-policy --role-name $ROLE --policy-name pc-eks-describe \
  --policy-document "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":\"eks:DescribeCluster\",\"Resource\":\"arn:aws:eks:$AWS_REGION:$ACCOUNT_ID:cluster/$CLUSTER\"}]}"

if ! aws iam get-instance-profile --instance-profile-name $PROFILE >/dev/null 2>&1; then
  aws iam create-instance-profile --instance-profile-name $PROFILE --tags $(tags_kv) >/dev/null
  aws iam add-role-to-instance-profile --instance-profile-name $PROFILE --role-name $ROLE
fi

# ── 인스턴스 ────────────────────────────────────────
MGMT_ID=$(ec2_id instance $MGMT_NAME)
if [ -z "$MGMT_ID" ]; then
  AMI=$(aws ssm get-parameter --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
    --query Parameter.Value --output text)
  # 도구(kubectl·helm·eksctl·trivy)는 버전·체크섬 고정이 필요해 user-data 가 아니라 별도 스크립트로 설치
  USER_DATA='#!/bin/bash
dnf install -y docker git jq mariadb105
systemctl enable --now docker'
  # 새로 만든 인스턴스 프로파일은 IAM 전파에 수 초가 걸린다 → 재시도
  for i in 1 2 3 4 5 6; do
    MGMT_ID=$(aws ec2 run-instances --image-id $AMI --instance-type $MGMT_TYPE \
      --subnet-id $SUBNET_MGMT_A --security-group-ids $SG_MGMT --no-associate-public-ip-address \
      --iam-instance-profile Name=$PROFILE \
      --metadata-options HttpTokens=required,HttpEndpoint=enabled \
      --block-device-mappings 'DeviceName=/dev/xvda,Ebs={VolumeSize=30,VolumeType=gp3,Encrypted=true}' \
      --user-data "$USER_DATA" \
      --tag-specifications "$(tagspec instance $MGMT_NAME)" "$(tagspec volume $MGMT_NAME)" \
      --query 'Instances[0].InstanceId' --output text 2>/dev/null) && break
    log "인스턴스 프로파일 전파 대기 ($i/6)"; sleep 10
  done
  [ -n "$MGMT_ID" ] || die "관리 EC2 생성 실패"
fi
save MGMT_ID

aws ec2 start-instances --instance-ids $MGMT_ID >/dev/null 2>&1 || true   # 중지 상태였다면 시작
aws ec2 wait instance-running --instance-ids $MGMT_ID

log "SSM 등록 대기 (최대 5분)"
for _ in $(seq 1 30); do
  st=$(aws ssm describe-instance-information --filters Key=InstanceIds,Values=$MGMT_ID \
    --query 'InstanceInformationList[0].PingStatus' --output text)
  [ "$st" = "Online" ] && { log "관리 EC2 $MGMT_ID SSM Online"; exit 0; }
  sleep 10
done
die "SSM 에 Online 으로 등록되지 않음 — NAT 경로·인스턴스 프로파일 확인"
