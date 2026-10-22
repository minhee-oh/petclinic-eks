#!/bin/bash
# 매일 작업 시작 — 기획서 3.2 기동 순서
#   ① 관리 EC2  ② RDS available  ③ 노드 2대 Ready  ④ kube-system 주석 복구(시스템 Pod 확인보다 먼저)
#   ⑤ 시스템 Pod Ready  ⑥ ExternalSecret 동기화  ⑦ 앱 replicas 복구(was → web)  ⑧ 대상 healthy + ALB 200 = 서비스 복귀
# 앱을 아직 배포하지 않은 날(2일차)에는 ⑥~⑧ 을 건너뛴다
set -euo pipefail
source "$(dirname "$0")/../env.sh"
require_aws 40

ANN=pc/replicas-before-stop

# 주석이 붙은 Deployment 를 주석 값으로 되돌리고 주석을 지운다
restore_annotated() {  # 네임스페이스 [라벨 셀렉터]
  local ns=$1 sel=${2:-} d r
  while read -r d r; do
    [ -n "$r" ] || continue
    kubectl scale deploy "$d" -n "$ns" --replicas="$r" >/dev/null
    kubectl annotate deploy "$d" -n "$ns" "$ANN-" >/dev/null
    log "$ns/$d replicas → $r (주석 복구)"
  done < <(kubectl get deploy -n "$ns" ${sel:+-l "$sel"} -o json \
           | jq -r --arg a "$ANN" '.items[] | [.metadata.name, (.metadata.annotations[$a] // "")] | @tsv')
}

# ① 관리 EC2
aws ec2 start-instances --instance-ids $MGMT_ID >/dev/null
aws ec2 wait instance-running --instance-ids $MGMT_ID
for _ in $(seq 1 30); do
  [ "$(aws ssm describe-instance-information --filters Key=InstanceIds,Values=$MGMT_ID \
      --query 'InstanceInformationList[0].PingStatus' --output text)" = Online ] && break
  sleep 10
done
log "관리 EC2 Online"

# ② RDS
st=$(aws rds describe-db-instances --db-instance-identifier $RDS_ID --query 'DBInstances[0].DBInstanceStatus' --output text)
[ "$st" = stopped ] && aws rds start-db-instance --db-instance-identifier $RDS_ID >/dev/null
log "RDS available 대기 (중지 상태였다면 5~10분)"
aws rds wait db-instance-available --db-instance-identifier $RDS_ID

# ③ 노드 그룹
aws eks update-nodegroup-config --cluster-name $CLUSTER --nodegroup-name $NODEGROUP \
  --scaling-config minSize=$NODE_COUNT,maxSize=$NODE_MAX,desiredSize=$NODE_COUNT >/dev/null
tunnel_up
log "노드 $NODE_COUNT대 Ready 대기"
for _ in $(seq 1 60); do
  [ "$(kubectl get nodes --no-headers 2>/dev/null | grep -cw Ready)" -ge $NODE_COUNT ] && break
  sleep 10
done
kubectl wait node --all --for=condition=Ready --timeout=60s

# ④ 전날 15분 판정에서 줄인 kube-system 이 있으면 먼저 되돌린다
#    CoreDNS 가 0 인 채로 남으면 was 가 DB 이름 `db` 를 못 찾아 전부 실패하므로 ⑤ 보다 앞
restore_annotated kube-system

# ⑤ 시스템 Pod
for d in coredns aws-load-balancer-controller; do
  kubectl rollout status deploy/$d -n kube-system --timeout=300s
done
if kubectl get ns external-secrets >/dev/null 2>&1; then
  kubectl rollout status deploy -n external-secrets --timeout=300s
fi

if ! kubectl get ns $NS >/dev/null 2>&1; then
  log "앱 네임스페이스 없음 — 노드·시스템 Pod 까지 복귀 완료"; exit 0
fi

# ⑥ ExternalSecret
if kubectl get externalsecret -n $NS --no-headers 2>/dev/null | grep -q .; then
  kubectl annotate externalsecret --all -n $NS force-sync="$(date +%s)" --overwrite >/dev/null
  kubectl wait externalsecret --all -n $NS --for=condition=Ready --timeout=120s
fi

# ⑦ 앱 — was 먼저(web 의 upstream), 그다음 나머지
restore_annotated $NS tier=was
kubectl rollout status deploy -n $NS -l tier=was --timeout=600s 2>/dev/null || true
restore_annotated $NS
kubectl rollout status deploy -n $NS --timeout=600s 2>/dev/null || true

# ⑧ 서비스 복귀 판정 — ALB 대상이 전부 healthy 이고 ALB 로 200
TGS=$(kubectl get targetgroupbindings -n $NS -o jsonpath='{.items[*].spec.targetGroupARN}' 2>/dev/null || true)
if [ -n "$TGS" ]; then
  for _ in $(seq 1 30); do
    bad=0
    for tg in $TGS; do
      n=$(aws elbv2 describe-target-health --target-group-arn "$tg" \
        --query "length(TargetHealthDescriptions[?TargetHealth.State!='healthy'])" --output text)
      [ "$n" = 0 ] || bad=1
    done
    [ $bad = 0 ] && break
    sleep 10
  done
  [ $bad = 0 ] || die "대상 그룹에 healthy 가 아닌 대상이 남음"
  log "대상 그룹 전부 healthy"
fi
ADDR=$(kubectl get gateway -n $NS -o jsonpath='{.items[0].status.addresses[0].value}' 2>/dev/null || true)
if [ -n "$ADDR" ]; then
  code=$(curl -s -o /dev/null -w '%{http_code}' "http://$ADDR/")
  [ "$code" = 200 ] || die "ALB 응답 $code"
  log "ALB 200 — 서비스 복귀: http://$ADDR/"
fi
