#!/bin/bash
# 사전 점검 — 조회만 한다 (자원 생성·요금 없음)
set -euo pipefail
source "$(dirname "$0")/../env.sh"
require_aws 5

echo "== 자격 증명"
aws sts get-caller-identity --query Arn --output text | sed -E 's/[0-9]{12}/<ACCOUNT_ID>/'

echo "== AZ ($AZ_A, $AZ_C)"
aws ec2 describe-availability-zones --zone-names $AZ_A $AZ_C \
  --query 'AvailabilityZones[].[ZoneName,State]' --output text

echo "== $NODE_TYPE / $MGMT_TYPE 제공 AZ (둘 다 2a·2c 에 있어야 함)"
for t in $NODE_TYPE $MGMT_TYPE; do
  printf '%s: ' $t
  aws ec2 describe-instance-type-offerings --location-type availability-zone \
    --filters Name=instance-type,Values=$t Name=location,Values=$AZ_A,$AZ_C \
    --query 'InstanceTypeOfferings[].Location' --output text
done

echo "== $RDS_CLASS MySQL $RDS_ENGINE_VERSION Multi-AZ 가능 여부"
aws rds describe-orderable-db-instance-options --engine mysql --engine-version $RDS_ENGINE_VERSION \
  --db-instance-class $RDS_CLASS --query 'OrderableDBInstanceOptions[?MultiAZCapable==`true`] | length(@)' --output text \
  | sed 's/^/Multi-AZ 가능한 조합 수: /'

echo "== 할당량 (필요량)"
quota() {  # 서비스 코드 이름 필요량
  local v; v=$(aws service-quotas get-service-quota --service-code $1 --quota-code $2 \
    --query Quota.Value --output text 2>/dev/null || echo "조회 실패")
  printf '%-45s 한도 %-8s 필요 %s\n' "$3" "$v" "$4"
}
# vCPU: 노드 4×2 + 노드 롤링 여유 4 + 관리 EC2 2 = 14
quota ec2 L-1216C47A "EC2 온디맨드 표준(A,C,D,H,I,M,R,T,Z) vCPU" 14
quota ec2 L-0263D0A3 "EC2-VPC 탄력적 IP"                           2
quota vpc L-FE5A380F "AZ당 NAT 게이트웨이"                         1
quota vpc L-F678F1CE "리전당 VPC"                                  1
echo "(사용 중인 수는 콘솔에서 확인 — 한도 - 사용량 >= 필요량 이어야 함)"
