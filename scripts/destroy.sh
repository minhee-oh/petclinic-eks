#!/bin/bash
# 프로젝트 정리 — 기획서 6장 순서. 4일차 저녁, 증빙 체크리스트(E1~E5) 통과 "후"에만
# 로컬에서 실행. 다시 실행해도 안전하다(이미 지운 것은 건너뜀) → 중간에 끊기면 그대로 다시 실행
# 이름 태그로 찾는다(.state.env 가 없어도 됨). 콘솔로 만든 자원 이름 차이(2일차 기록)도 반영:
#   관리 EC2 인스턴스 프로파일 = pc-role-mgmt, 콘솔이 자동 생성한 rds-monitoring-role
# 한 단계가 실패하면 기록만 하고 다음으로 간다 → 마지막 "남은 자원" 목록을 보고 다시 실행
set -uo pipefail
source "$(dirname "$0")/../env.sh"   # 변수·함수 정의만 (AWS 호출 없음)
# 사람이 터미널에서 직접 실행할 때만 — 파이프·비대화형 입력(자동화 도구 포함)으로는 아래 확인을 통과할 수 없게
# 첫 동작이어야 한다: 이 줄보다 앞에 AWS·kubectl 호출을 두지 않는다
[ -t 0 ] || die "destroy.sh 는 터미널에서 직접 실행해야 합니다 (파이프·비대화형 입력 거부)"
require_aws 90   # NAT·RDS·클러스터 삭제 대기 포함 40~60분

echo "pc-* 자원을 모두 삭제합니다 (RDS 는 최종 스냅샷을 남김)."
echo "증빙 체크리스트 E1~E5 를 모두 통과했는지 먼저 확인하세요."
read -r -p "계속하려면 클러스터 이름($CLUSTER)을 입력: " ANS
[ "$ANS" = "$CLUSTER" ] || die "취소"

FAILS=()
try() {  # 설명 명령... — 실패해도 계속, 끝에 모아서 보여 준다
  local what=$1; shift
  if "$@" >/dev/null 2>&1; then log "✔ $what"; else log "✘ $what"; FAILS+=("$what"); fi
}
exists() { "$@" >/dev/null 2>&1; }
SNAP=pc-rds-final-$(date +%Y%m%d-%H%M)   # 같은 날 두 번 철거해도 이름이 겹치지 않게 (10/26 재구축)
CLUSTER_UP=0; exists aws eks describe-cluster --name $CLUSTER && CLUSTER_UP=1

# ── 1. HTTPRoute·Gateway → ALB·대상 그룹·LBC SG 가 사라질 때까지 ──
# LBC 가 살아 있을 때 지워야 LBC 가 ALB 를 정리한다(클러스터를 먼저 지우면 ALB·ENI 가 고아로 남아 VPC 삭제 실패)
alb_left() {
  aws resourcegroupstaggingapi get-resources --resource-type-filters elasticloadbalancing:loadbalancer elasticloadbalancing:targetgroup \
    --tag-filters Key=elbv2.k8s.aws/cluster,Values=$CLUSTER --query 'length(ResourceTagMappingList)' --output text
}
MGMT_UP=0; [ "$(aws ec2 describe-instances --filters Name=tag:Name,Values=pc-mgmt Name=instance-state-name,Values=running \
  --query 'length(Reservations)' --output text)" = 0 ] || MGMT_UP=1
# 다시 실행할 때: 관리 EC2 가 이미 종료돼 터널(=쿠버네티스 API)이 없다 → ALB 가 0 이면 1·2 단계는 끝난 것으로 보고 건너뜀
if [ $CLUSTER_UP = 1 ] && [ $MGMT_UP = 0 ]; then
  [ "$(alb_left)" = 0 ] || die "관리 EC2 가 없어 쿠버네티스 API 에 못 가는데 ALB 가 남아 있음 — 콘솔에서 ALB 확인 필요"
  log "관리 EC2 없음 · ALB 0 — 쿠버네티스 정리(1·2단계)는 끝난 것으로 보고 건너뜀"
fi
if [ $CLUSTER_UP = 1 ] && [ $MGMT_UP = 1 ]; then
  [ "$(aws eks describe-nodegroup --cluster-name $CLUSTER --nodegroup-name $NODEGROUP \
        --query nodegroup.scalingConfig.desiredSize --output text 2>/dev/null)" != 0 ] \
    || die "노드 0대 — LBC 가 없어 ALB 를 못 지움. start.sh 로 기동 후 다시 실행"
  tunnel_up
  kubectl delete httproute,gateway --all -n $NS --wait=true --timeout=5m
  log "ALB 삭제 대기 (LBC 가 만든 elbv2.k8s.aws/cluster=$CLUSTER 태그)"
  for _ in $(seq 1 60); do
    n=$(alb_left)
    [ "$n" = 0 ] && break
    sleep 10
  done
  [ "$n" = 0 ] && log "✔ ALB·대상 그룹 삭제" || { log "✘ ALB·대상 그룹이 10분 뒤에도 남음"; FAILS+=("ALB"); }
  # 앱 네임스페이스(Deployment·Job·ExternalSecret) — ESO 가 살아 있을 때 지워 finalizer 가 걸리지 않게
  try "네임스페이스 $NS" kubectl delete ns $NS --wait=true --timeout=5m

  # ── 2. Helm 릴리스 ──
  try "Helm external-secrets" helm uninstall external-secrets -n external-secrets --wait
  try "Helm LBC"              helm uninstall aws-load-balancer-controller -n kube-system --wait
  tunnel_down
fi

# ── 3. 노드 그룹 → 클러스터 (eksctl 이 만든 CloudFormation 스택을 직접 지운다) ──
# eksctl delete cluster 는 시작할 때 쿠버네티스 API 로 Service 를 조회(LB 정리)하는데, API 는 프라이빗 전용이라
# 터널을 닫은 뒤에는 실패한다(10/26 실측: 'cannot list Kubernetes Services' → 클러스터·노드가 그대로 남음).
# LB 정리는 1단계에서 ALB 0 으로 이미 확인했으므로 스택 삭제만 하면 된다
del_stacks() {  # 이름 앞부분(eksctl-<클러스터>- 뒤) — 해당 스택을 모두 지우고 끝날 때까지 기다림
  local s
  for s in $(aws cloudformation list-stacks --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE DELETE_FAILED \
               --query "StackSummaries[?starts_with(StackName,'eksctl-$CLUSTER-$1')].StackName" --output text); do
    log "스택 삭제: $s"
    # eksctl 은 스택에 종료 보호를 켜 두고 자기 delete 때만 끈다 → 직접 지울 때는 먼저 끈다
    aws cloudformation update-termination-protection --no-enable-termination-protection --stack-name "$s" >/dev/null \
      && aws cloudformation delete-stack --stack-name "$s" \
      || { log "✘ $s (삭제 요청 실패)"; FAILS+=("스택 $s"); continue; }
    if aws cloudformation wait stack-delete-complete --stack-name "$s"; then log "✔ $s"
    else log "✘ $s"; FAILS+=("스택 $s"); fi
  done
}
if [ $CLUSTER_UP = 1 ]; then
  log "클러스터 삭제 (15~20분)"
  del_stacks podidentityrole-
  del_stacks accessentry-
  del_stacks nodegroup-      # 노드 종료 — 노드 ENI 가 사라져야 서브넷·SG 를 지울 수 있다
  del_stacks cluster         # 클러스터 + eksctl 이 만든 SG(ControlPlaneSecurityGroup)
  exists aws eks describe-cluster --name $CLUSTER && { log "✘ EKS 클러스터"; FAILS+=("EKS 클러스터"); } || log "✔ EKS 클러스터"
fi
left=$(aws cloudformation list-stacks --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE DELETE_FAILED \
        --query "StackSummaries[?starts_with(StackName,'eksctl-$CLUSTER-')].StackName" --output text)
[ -z "$left" ] || { log "✘ eksctl 스택 남음: $left"; FAILS+=("eksctl 스택"); }

# ── 5. RDS Proxy → RDS (삭제 방지 해제 → 최종 스냅샷) ──
# 6장의 4(IAM)·6(관리 EC2) 보다 먼저: RDS 삭제가 가장 오래 걸리므로 일찍 시작해 두고 나머지를 병행
for p in $(aws rds describe-db-proxies --query "DBProxies[?starts_with(DBProxyName,'pc-')].DBProxyName" --output text 2>/dev/null); do
  try "RDS Proxy $p" aws rds delete-db-proxy --db-proxy-name "$p"
done
# PITR 리허설 복원본(77-pitr.sh) — 리허설용이라 스냅샷 없이. 같은 서브넷 그룹·SG 를 써서 남으면 9·10 단계가 막힌다
if exists aws rds describe-db-instances --db-instance-identifier pc-rds-pitr; then
  try "PITR 복원본 삭제 방지 해제" aws rds modify-db-instance --db-instance-identifier pc-rds-pitr --no-deletion-protection --apply-immediately
  try "PITR 복원본 삭제 요청" aws rds delete-db-instance --db-instance-identifier pc-rds-pitr \
        --skip-final-snapshot --delete-automated-backups
fi
st=$(aws rds describe-db-instances --db-instance-identifier $RDS_ID --query 'DBInstances[0].DBInstanceStatus' --output text 2>/dev/null || echo none)
case $st in
  none|deleting) log "RDS 상태 $st — 삭제 요청 생략" ;;
  *)
    try "RDS 삭제 방지 해제" aws rds modify-db-instance --db-instance-identifier $RDS_ID --no-deletion-protection --apply-immediately
    try "RDS 삭제 요청 (스냅샷 $SNAP)" aws rds delete-db-instance --db-instance-identifier $RDS_ID \
          --final-db-snapshot-identifier $SNAP ;;   # 자동 백업은 함께 삭제(기본값) — 남는 것은 최종 스냅샷 1개
esac

# ── 6. 관리 EC2 → ECR ── (인스턴스 프로파일을 쓰는 인스턴스가 없어야 4의 역할 삭제가 된다)
MGMT=$(ec2_id instance $MGMT_NAME)
if [ -n "$MGMT" ]; then
  try "관리 EC2 종료" aws ec2 terminate-instances --instance-ids $MGMT
  aws ec2 wait instance-terminated --instance-ids $MGMT
fi
for R in pc-web pc-was; do
  exists aws ecr describe-repositories --repository-names $R && try "ECR $R" aws ecr delete-repository --repository-name $R --force
done
# 향상된 스캔은 레지스트리(계정) 설정 — 저장소가 없어도 규칙이 남으므로 기본 스캔으로 되돌린다
try "ECR 레지스트리 스캔 BASIC" aws ecr put-registry-scanning-configuration --scan-type BASIC --rules '[]'

# ── 4. IAM — 역할에서 정책 분리 → 역할·프로파일 → 고객 관리형 정책 ──
del_role() {  # 역할 이름 — 붙은 정책·인라인 정책·인스턴스 프로파일까지 정리
  local r=$1 p
  exists aws iam get-role --role-name "$r" || return 0
  for p in $(aws iam list-attached-role-policies --role-name "$r" --query 'AttachedPolicies[].PolicyArn' --output text); do
    aws iam detach-role-policy --role-name "$r" --policy-arn "$p"
  done
  for p in $(aws iam list-role-policies --role-name "$r" --query 'PolicyNames[]' --output text); do
    aws iam delete-role-policy --role-name "$r" --policy-name "$p"
  done
  for p in $(aws iam list-instance-profiles-for-role --role-name "$r" --query 'InstanceProfiles[].InstanceProfileName' --output text); do
    aws iam remove-role-from-instance-profile --instance-profile-name "$p" --role-name "$r"
    aws iam delete-instance-profile --instance-profile-name "$p"
  done
  aws iam delete-role --role-name "$r"
}
for r in pc-role-lbc pc-role-eso pc-role-mgmt pc-role-rds-proxy rds-monitoring-role; do   # lbc·eso 는 보통 eksctl 이 이미 지움
  try "IAM 역할 $r" del_role $r
done
for p in pc-policy-lbc pc-policy-eso; do
  arn=arn:aws:iam::$ACCOUNT_ID:policy/$p
  exists aws iam get-policy --policy-arn $arn && try "IAM 정책 $p" aws iam delete-policy --policy-arn $arn
done

# ── 7. Secrets Manager — 복구 기간 7일 (RDS 관리형 master 비밀은 RDS 삭제와 함께 사라짐) ──
for s in pc/petclinic/app-db pc/petclinic/migration-db; do
  st=$(aws secretsmanager describe-secret --secret-id $s --query DeletedDate --output text 2>/dev/null || echo none)
  [ "$st" = None ] && try "비밀 $s (7일 뒤 삭제)" aws secretsmanager delete-secret --secret-id $s --recovery-window-in-days 7
done

# ── 8. CloudWatch 로그 그룹 ──
# Git Bash 는 '/'로 시작하는 인자를 Windows 경로(C:/Program Files/Git/aws/...)로 바꿔 넘긴다 → MSYS_NO_PATHCONV=1
for prefix in /aws/eks/$CLUSTER/ /aws/rds/instance/$RDS_ID/ /aws/rds/proxy/pc-; do
  for g in $(MSYS_NO_PATHCONV=1 aws logs describe-log-groups --log-group-name-prefix "$prefix" --query 'logGroups[].logGroupName' --output text); do
    try "로그 그룹 $g" env MSYS_NO_PATHCONV=1 aws logs delete-log-group --log-group-name "$g"
  done
done

# ── 9. RDS 삭제 완료 후 서브넷 그룹·파라미터 그룹 ──
if exists aws rds describe-db-instances --db-instance-identifier $RDS_ID; then
  log "RDS 삭제 완료 대기 (Multi-AZ, 10~20분)"
  aws rds wait db-instance-deleted --db-instance-identifier $RDS_ID
fi
if exists aws rds describe-db-instances --db-instance-identifier pc-rds-pitr; then
  log "PITR 복원본 삭제 완료 대기"
  aws rds wait db-instance-deleted --db-instance-identifier pc-rds-pitr
fi
# Proxy 는 DB 서브넷에 ENI 를 두고, pc-sg-proxy 를 쓴다 → 다 사라져야 10 단계의 SG·서브넷 삭제가 된다
for _ in $(seq 1 40); do
  [ "$(aws rds describe-db-proxies --query "length(DBProxies[?starts_with(DBProxyName,'pc-')])" --output text 2>/dev/null || echo 0)" = 0 ] && break
  log "RDS Proxy 삭제 대기"; sleep 15
done
exists aws rds describe-db-subnet-groups --db-subnet-group-name pc-dbsubnet && \
  try "DB 서브넷 그룹" aws rds delete-db-subnet-group --db-subnet-group-name pc-dbsubnet
exists aws rds describe-db-parameter-groups --db-parameter-group-name pc-mysql84 && \
  try "DB 파라미터 그룹" aws rds delete-db-parameter-group --db-parameter-group-name pc-mysql84

# ── 10. NAT → EIP → S3 엔드포인트 → SG → 서브넷 → 라우트 테이블 → IGW → VPC ──
VPC=$(ec2_id vpc pc-vpc)
if [ -n "$VPC" ]; then
  NATS=$(aws ec2 describe-nat-gateways --filter Name=vpc-id,Values=$VPC Name=state,Values=pending,available \
           --query 'NatGateways[].NatGatewayId' --output text)
  for n in $NATS; do try "NAT $n" aws ec2 delete-nat-gateway --nat-gateway-id $n; done
  [ -z "$NATS" ] || { log "NAT 삭제 대기"; aws ec2 wait nat-gateway-deleted --nat-gateway-ids $NATS; }
  for e in pc-eip-nat-a pc-eip-nat-c; do
    id=$(ec2_id eip $e); [ -z "$id" ] || try "EIP $e" aws ec2 release-address --allocation-id $id
  done
  for v in $(aws ec2 describe-vpc-endpoints --filters Name=vpc-id,Values=$VPC --query 'VpcEndpoints[].VpcEndpointId' --output text); do
    try "VPC 엔드포인트 $v" aws ec2 delete-vpc-endpoints --vpc-endpoint-ids $v
  done

  # SG 끼리 참조하는 규칙부터 제거 → SG 삭제 (k8s-* 등 남은 것 포함, default 제외)
  SGS=$(aws ec2 describe-security-groups --filters Name=vpc-id,Values=$VPC \
          --query 'SecurityGroups[?GroupName!=`default`].GroupId' --output text)
  for g in $SGS; do
    for rule in $(aws ec2 describe-security-group-rules --filters Name=group-id,Values=$g \
                    --query 'SecurityGroupRules[?ReferencedGroupInfo.GroupId && !IsEgress].SecurityGroupRuleId' --output text); do
      aws ec2 revoke-security-group-ingress --group-id $g --security-group-rule-ids $rule >/dev/null 2>&1
    done
  done
  for g in $SGS; do try "SG $g" aws ec2 delete-security-group --group-id $g; done

  # 남은 ENI 가 있으면 서브넷 삭제가 실패한다 → 먼저 보여 준다
  enis=$(aws ec2 describe-network-interfaces --filters Name=vpc-id,Values=$VPC \
           --query 'NetworkInterfaces[].[NetworkInterfaceId,Description]' --output text)
  [ -z "$enis" ] || log "남은 ENI (서브넷 삭제 실패 원인):"$'\n'"$enis"
  for s in $(aws ec2 describe-subnets --filters Name=vpc-id,Values=$VPC --query 'Subnets[].SubnetId' --output text); do
    try "서브넷 $s" aws ec2 delete-subnet --subnet-id $s
  done
  for r in $(aws ec2 describe-route-tables --filters Name=vpc-id,Values=$VPC \
               --query 'RouteTables[?!(Associations[?Main])].RouteTableId' --output text); do
    try "라우트 테이블 $r" aws ec2 delete-route-table --route-table-id $r
  done
  IGW=$(ec2_id igw pc-igw)
  if [ -n "$IGW" ]; then
    try "IGW 분리" aws ec2 detach-internet-gateway --internet-gateway-id $IGW --vpc-id $VPC
    try "IGW 삭제" aws ec2 delete-internet-gateway --internet-gateway-id $IGW
  fi
  try "VPC" aws ec2 delete-vpc --vpc-id $VPC
fi

# ── 11. 확인 ──
echo "== 남은 Project=$TAG_PROJECT 태그 자원 (삭제 직후 몇 분은 보일 수 있음. 스냅샷 1개는 정상)"
aws resourcegroupstaggingapi get-resources --tag-filters Key=Project,Values=$TAG_PROJECT \
  --query 'ResourceTagMappingList[].ResourceARN' --output text | tr '\t' '\n' | sed "s/$ACCOUNT_ID/************/"
echo "== 최종 스냅샷"
aws rds describe-db-snapshots --db-snapshot-identifier $SNAP \
  --query 'DBSnapshots[0].[DBSnapshotIdentifier,Status,SnapshotCreateTime]' --output text 2>/dev/null || echo "(없음)"
echo "== 로컬 정리(수동): hosts 의 EKS 엔드포인트 줄, ~/.kube/config 의 $CLUSTER 컨텍스트"
echo "== 리소스 대장: 스냅샷 $SNAP 삭제일 2026-11-04"
if [ ${#FAILS[@]} -gt 0 ]; then
  printf '실패 %d건 — 다시 실행하면 이어서 정리:\n' ${#FAILS[@]}; printf '  - %s\n' "${FAILS[@]}"
  exit 1
fi
log "정리 완료"
