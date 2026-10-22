#!/bin/bash
# EKS 클러스터 — 생성 중에만 퍼블릭 /32 → 생성 직후 프라이빗 전용 (기획서 2.3, 결정 기록 "EKS 생성 방식")
# 다시 실행하면 이어서 진행한다: 공개가 남아 있으면 닫고, 컨트롤 플레인 서브넷이 다르면 옮긴다
# EKS 는 업데이트를 한 번에 하나만 받는다 → 단계마다 describe-update 가 Successful 인지 확인 후 다음 단계
# 사용: DRY_RUN=1 scripts/30-cluster.sh   # 1일차 — 템플릿 렌더 + eksctl --dry-run 만
#       scripts/30-cluster.sh             # 2일차 — 실제 생성 (🔒 승인 후)
set -euo pipefail
source "$(dirname "$0")/../env.sh"
require_aws 60          # 생성 20~30분 + 업데이트 2회. 도중 만료 방지

CFG="$PC_HOME/infra/cluster.yaml"

cluster_exists() { aws eks describe-cluster --name $CLUSTER >/dev/null 2>&1; }

# 진행 중인 클러스터 업데이트가 끝날 때까지 대기. Failed 면 중단
wait_updates() {
  local id st
  for id in $(aws eks list-updates --name $CLUSTER --query 'updateIds[]' --output text); do
    while :; do
      st=$(aws eks describe-update --name $CLUSTER --update-id "$id" --query update.status --output text)
      case $st in
        Successful|Cancelled) break ;;
        Failed) die "클러스터 업데이트 $id 실패: $(aws eks describe-update --name $CLUSTER --update-id "$id" --query update.errors --output text)" ;;
        *) log "업데이트 $id $st — 대기"; sleep 20 ;;
      esac
    done
  done
  aws eks wait cluster-active --name $CLUSTER
}

vpc_cfg() { aws eks describe-cluster --name $CLUSTER --query "cluster.resourcesVpcConfig.$1" --output text; }

# 퍼블릭 엔드포인트가 열려 있으면 닫는다 — 생성 직후, 그리고 도중 실패 뒤 재실행 때 모두 여기서 복구
close_public() {
  wait_updates
  if [ "$(vpc_cfg endpointPublicAccess)" = True ]; then
    log "퍼블릭 엔드포인트 닫는 중 (프라이빗 전용)"
    aws eks update-cluster-config --name $CLUSTER \
      --resources-vpc-config endpointPublicAccess=false,endpointPrivateAccess=true >/dev/null
    wait_updates
  fi
  [ "$(vpc_cfg endpointPublicAccess)" = False ] || die "퍼블릭 엔드포인트가 아직 열려 있음"
  log "endpointPublicAccess=false 확인"
}

# 컨트롤 플레인 ENI 서브넷을 mgmt a·c 로
move_control_plane() {
  wait_updates
  local cur want
  cur=$(vpc_cfg 'subnetIds' | tr '\t' '\n' | sort | xargs)
  want=$(printf '%s\n' $SUBNET_MGMT_A $SUBNET_MGMT_C | sort | xargs)
  if [ "$cur" != "$want" ]; then
    log "컨트롤 플레인 서브넷 [$cur] → [$want]"
    aws eks update-cluster-config --name $CLUSTER \
      --resources-vpc-config "subnetIds=$SUBNET_MGMT_A,$SUBNET_MGMT_C" >/dev/null
    wait_updates
  fi
  log "컨트롤 플레인 서브넷 = mgmt a·c 확인"
}

# ── 0. 재실행 복구: 클러스터가 이미 있으면 공개부터 닫는다 ──
if cluster_exists && [ "${DRY_RUN:-0}" != 1 ]; then
  close_public
fi

# ── 1. IAM 정책 (Pod Identity 연결 대상) — 클러스터 생성 전에 있어야 한다 ──
if ! aws iam get-policy --policy-arn arn:aws:iam::$ACCOUNT_ID:policy/pc-policy-lbc >/dev/null 2>&1; then
  curl -fsSL -o "$PC_HOME/infra/lbc-iam-policy.json" \
    https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/$LBC_VERSION/docs/install/iam_policy.json
  aws iam create-policy --policy-name pc-policy-lbc --tags $(tags_kv) \
    --policy-document "file://$PC_HOME/infra/lbc-iam-policy.json" >/dev/null
  log "pc-policy-lbc 생성 ($LBC_VERSION 태그 정책)"
fi
# ESO 는 이 프로젝트 비밀(pc/petclinic/*)만 읽는다. RDS master 비밀(rds!...)은 범위 밖 = 클러스터에 들어오지 않음
if ! aws iam get-policy --policy-arn arn:aws:iam::$ACCOUNT_ID:policy/pc-policy-eso >/dev/null 2>&1; then
  aws iam create-policy --policy-name pc-policy-eso --tags $(tags_kv) --policy-document "{
    \"Version\":\"2012-10-17\",
    \"Statement\":[{\"Effect\":\"Allow\",
      \"Action\":[\"secretsmanager:GetSecretValue\",\"secretsmanager:DescribeSecret\"],
      \"Resource\":\"arn:aws:secretsmanager:$AWS_REGION:$ACCOUNT_ID:secret:pc/petclinic/*\"}]}" >/dev/null
  log "pc-policy-eso 생성"
fi

# ── 2. 템플릿 렌더 — /32 는 실행 직전에 조회 ──
# envsubst 는 빈 변수를 빈 문자열로 바꾸므로 먼저 확인 (10-network.sh 를 안 돌렸으면 서브넷 ID 가 없다)
for v in VPC_ID SUBNET_APP_A SUBNET_APP_C SUBNET_MGMT_A SUBNET_MGMT_C SG_NODE; do
  [ -n "${!v:-}" ] || die "$v 없음 — 10-network.sh 먼저 (dry-run 도 실제 서브넷 ID 가 필요)"
done
export MY_IP=$(curl -fsS https://checkip.amazonaws.com | tr -d '\r\n')
[[ $MY_IP =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "공인 IP 조회 실패: $MY_IP"
export ACCOUNT_ID
envsubst < "$PC_HOME/infra/cluster.yaml.tpl" > "$CFG"
grep -q '\${' "$CFG" && die "치환되지 않은 변수가 남음: $(grep -o '\${[A-Z_]*}' "$CFG" | sort -u | xargs)"
log "infra/cluster.yaml 렌더 (생성 중 허용 IP $MY_IP/32)"

# ── 3. 생성 ──
if ! cluster_exists; then
  eksctl create cluster -f "$CFG" --dry-run > "$PC_HOME/infra/cluster.dry-run.yaml"
  if grep -q controlPlaneSubnetIDs "$PC_HOME/infra/cluster.dry-run.yaml"; then
    log "dry-run: controlPlaneSubnetIDs 반영됨"
  else
    log "dry-run: controlPlaneSubnetIDs 미반영 → 생성 후 move_control_plane 에서 옮김"
  fi
  if [ "${DRY_RUN:-0}" = 1 ]; then log "DRY_RUN — 여기서 끝 (infra/cluster.dry-run.yaml 확인)"; exit 0; fi

  log "클러스터 생성 시작 (20~30분). 이 동안만 퍼블릭 엔드포인트가 $MY_IP/32 로 열림"
  eksctl create cluster -f "$CFG"
fi
[ "${DRY_RUN:-0}" = 1 ] && { log "클러스터가 이미 있어 dry-run 생략"; exit 0; }

# ── 4. 업데이트는 하나씩: 서브넷 → 엔드포인트 ──
move_control_plane
close_public

# ── 5. 관리 EC2 → API 443 (클러스터 SG 는 이제 존재) ──
CLUSTER_SG=$(vpc_cfg clusterSecurityGroupId); save CLUSTER_SG
allow_sg $CLUSTER_SG 443 $SG_MGMT "mgmt EC2 to EKS private endpoint"

# ── 6. 증빙 📸 ──
echo "== 엔드포인트 (증빙: endpointPublicAccess=false)"
aws eks describe-cluster --name $CLUSTER \
  --query 'cluster.resourcesVpcConfig.{public:endpointPublicAccess,private:endpointPrivateAccess,subnets:subnetIds}' --output table
echo "== 컨트롤 플레인 ENI 위치 (mgmt a·c 여야 함)"
aws ec2 describe-network-interfaces --filters "Name=description,Values=Amazon EKS $CLUSTER" \
  --query 'NetworkInterfaces[].[SubnetId,AvailabilityZone,PrivateIpAddress]' --output table
echo "== 애드온·Pod Identity"
aws eks describe-addon --cluster-name $CLUSTER --addon-name vpc-cni --query addon.configurationValues --output text
aws eks describe-addon --cluster-name $CLUSTER --addon-name eks-pod-identity-agent --query addon.status --output text
aws eks list-pod-identity-associations --cluster-name $CLUSTER \
  --query 'associations[].[namespace,serviceAccount]' --output table

# ── 7. 노드 SG 확인 — 둘 다 붙어 있지 않으면 중단 ──
# 관리형 노드 그룹에 SG 를 직접 지정하면 클러스터 SG 가 자동으로 안 붙을 수 있다
#   클러스터 SG 가 없으면: "클러스터 SG 를 노드에서 떼지 않는다" 원칙 위반(노드 ↔ API·웹훅)
#   pc-sg-node 가 없으면: RDS 3306 규칙의 출처가 아니므로 was → RDS 불가
echo "== 노드 ENI 의 SG (클러스터 SG + pc-sg-node 둘 다 있어야 함)"
NODES=$(aws ec2 describe-instances \
  --filters "Name=tag:eks:nodegroup-name,Values=$NODEGROUP" Name=instance-state-name,Values=running \
  --query 'Reservations[].Instances[].InstanceId' --output text)
[ -n "$NODES" ] || die "실행 중인 노드가 없음"
for i in $NODES; do
  sgs=$(aws ec2 describe-instances --instance-ids $i \
    --query 'Reservations[0].Instances[0].NetworkInterfaces[?Attachment.DeviceIndex==`0`].Groups[].GroupId' --output text)
  echo "$i: $sgs"
  [[ " $sgs " == *" $CLUSTER_SG "* ]] || die "$i 에 클러스터 SG($CLUSTER_SG) 없음 — 원칙 위반. 노드 그룹 SG 설정 재검토 후 진행"
  [[ " $sgs " == *" $SG_NODE "* ]]    || die "$i 에 pc-sg-node($SG_NODE) 없음 — RDS 접속 불가"
done
log "노드 SG 확인 (클러스터 SG + pc-sg-node)"
log "클러스터 완료. 이후 쿠버네티스 API 작업(40-addons 등)은 터널 또는 관리 EC2 경유"
