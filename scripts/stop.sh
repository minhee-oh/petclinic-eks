#!/bin/bash
# 매일 작업 종료 — 기획서 3.2 중지 순서
#   ① 앱 replicas 기록(주석) → 0   ② 노드 그룹 0 → 15분 판정   ③ RDS 중지   ④ 관리 EC2 중지(터널 경로라 마지막)
# 밤사이에도 과금: EKS 컨트롤 플레인, NAT 2개, ALB, EIP, RDS 스토리지
set -euo pipefail
source "$(dirname "$0")/../env.sh"
require_aws 40
tunnel_up

ANN=pc/replicas-before-stop
LOG_DIR="$PC_HOME/logs/stop-$(date +%Y%m%d-%H%M)"

# 네임스페이스의 Deployment 마다 현재 replicas 를 주석으로 남기고 0 으로 줄인다
# 이미 0 인 것(두 번째 실행 등)은 주석을 덮어쓰지 않는다
scale_down_annotated() {  # 네임스페이스 [Deployment 이름...]
  local ns=$1; shift
  local names=("$@") d r
  [ ${#names[@]} -gt 0 ] || mapfile -t names < <(kubectl get deploy -n "$ns" -o name 2>/dev/null)
  for d in "${names[@]}"; do
    d=${d#deployment.apps/}
    r=$(kubectl get deploy "$d" -n "$ns" -o jsonpath='{.spec.replicas}')
    if [ "$r" != 0 ]; then
      kubectl annotate deploy "$d" -n "$ns" "$ANN=$r" --overwrite >/dev/null
      kubectl scale deploy "$d" -n "$ns" --replicas=0 >/dev/null
      log "$ns/$d replicas $r → 0 (주석 기록)"
    fi
  done
}

# ① 앱 — replicas 0 이면 HPA 는 스스로 멈추고, 앱 PDB 는 막을 Pod 가 없어진다
scale_down_annotated $NS

# ② 노드 그룹 0
aws eks update-nodegroup-config --cluster-name $CLUSTER --nodegroup-name $NODEGROUP \
  --scaling-config minSize=0,maxSize=$NODE_MAX,desiredSize=0 >/dev/null
log "노드 그룹 0 요청 — 15분 판정 시작"

wait_nodes_zero() {  # 초
  local end=$(( $(date +%s) + $1 )) n
  while [ "$(date +%s)" -lt "$end" ]; do
    n=$(asg_instances); [ "$n" = 0 ] && return 0
    sleep 30
  done
  return 1
}

if ! wait_nodes_zero 900; then
  # 막힘 판정 — 이때만(조건부) kube-system 을 건드린다. 막히지 않은 밤에는 이 블록이 실행되지 않는다
  log "15분이 지나도 노드가 줄지 않음 = 막힘. 원인 기록: $LOG_DIR"
  tunnel_up   # 15분 대기 동안 kubectl 을 안 써서 SSM 유휴 제한(20분)에 가까움 → 닫혔으면 다시 연다
  mkdir -p "$LOG_DIR"
  kubectl get pdb -A -o wide            > "$LOG_DIR/pdb.txt" 2>&1 || true
  kubectl get pods -A -o wide           > "$LOG_DIR/pods.txt" 2>&1 || true
  aws eks describe-nodegroup --cluster-name $CLUSTER --nodegroup-name $NODEGROUP \
    --query nodegroup.health             > "$LOG_DIR/nodegroup-health.json" 2>&1 || true

  # 허용 중단 수 0 인 PDB 가 고르는 Pod 를 가진 kube-system Deployment
  mapfile -t blockers < <(kubectl get pdb,deploy -n kube-system -o json | jq -r '
    [.items[] | select(.kind=="PodDisruptionBudget" and .status.disruptionsAllowed==0) | .spec.selector.matchLabels] as $p
    | .items[] | select(.kind=="Deployment") | . as $d
    | select(any($p[]; . as $l | ($d.spec.template.metadata.labels // {}) | contains($l)))
    | .metadata.name')
  [ ${#blockers[@]} -gt 0 ] || die "PDB 원인을 찾지 못함 — $LOG_DIR 확인 후 트러블슈팅에 기록"
  log "막은 Deployment: ${blockers[*]} → 오늘 밤만 0 (start.sh 가 주석 값으로 복구)"
  printf '%s\n' "${blockers[@]}" > "$LOG_DIR/blockers.txt"
  scale_down_annotated kube-system "${blockers[@]}"

  wait_nodes_zero 900 || die "kube-system 축소 후에도 15분 안에 노드가 줄지 않음 — $LOG_DIR 확인"
  log "트러블슈팅 기록 필요: $LOG_DIR"
fi
log "노드 0 확인"

# ③ RDS 중지 (Multi-AZ 도 중지 가능. 7일 뒤 자동 시작됨)
st=$(aws rds describe-db-instances --db-instance-identifier $RDS_ID --query 'DBInstances[0].DBInstanceStatus' --output text)
if [ "$st" = available ]; then
  aws rds stop-db-instance --db-instance-identifier $RDS_ID >/dev/null
  log "RDS 중지 요청"
else
  log "RDS 상태 $st — 중지 요청 생략"
fi

# ④ 관리 EC2 — 터널을 먼저 닫는다
tunnel_down
aws ec2 stop-instances --instance-ids $MGMT_ID >/dev/null
log "관리 EC2 중지 요청. 전체 중지 완료: $(date '+%F %T')"
