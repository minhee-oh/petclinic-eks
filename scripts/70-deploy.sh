#!/bin/bash
# 앱 배포 — 로컬에서 실행 (터널은 tunnel_up 이 자동으로 엶)
# 순서: 네임스페이스·비밀 → 초기화 Job 완료 대기(실패 시 중단)
#   → Service(was·web·db) → Gateway·HTTPRoute·TGC → TargetGroupBinding 생성 대기 → Deployment(was → web)
# 다시 실행해도 안전: Job 은 해시가 같으면 그대로(완료 상태), 나머지는 apply
set -euo pipefail
source "$(dirname "$0")/../env.sh"
require_aws 20
cd "$PC_HOME"
tunnel_up
NS=petclinic

# ── 네임스페이스·비밀 (3-2 에서 이미 적용 — 다시 적용해도 그대로) ──────
kubectl apply -f k8s/00-namespace.yaml -f k8s/10-secrets.yaml
kubectl -n $NS wait externalsecret/migration-db --for=condition=Ready --timeout=60s
# NetworkPolicy (4-3) — 초기화 Job 보다 먼저: Job 도 정책 아래에서 DB 에 닿는지 매번 확인된다
kubectl apply -f k8s/50-netpol.yaml

# ── 초기화 Job (3-6) ───────────────────────────────
DB_HOST=$(aws rds describe-db-instances --db-instance-identifier $RDS_ID \
  --query 'DBInstances[0].Endpoint.Address' --output text)
HASH=$(cat k8s/db/schema.sql k8s/db/data.sql k8s/60-db-init-job.yaml | tr -d '\r' | sha256sum | cut -c1-8)
JOB=petclinic-db-init-$HASH
log "초기화 Job $JOB (DB $DB_HOST)"

kubectl -n $NS create configmap petclinic-db-sql-$HASH \
  --from-file=k8s/db/schema.sql --from-file=k8s/db/data.sql --dry-run=client -o yaml \
  | kubectl label --local -f - tier=db-init -o yaml | kubectl apply -f -
sed -e "s/__HASH__/$HASH/g" -e "s/__DB_HOST__/$DB_HOST/g" k8s/60-db-init-job.yaml | kubectl apply -f -

# Complete 또는 Failed 중 먼저 오는 쪽 (kubectl wait 는 한 조건만 기다린다)
for _ in $(seq 1 60); do
  st=$(kubectl -n $NS get job $JOB -o jsonpath='{range .status.conditions[?(@.status=="True")]}{.type} {end}')
  case "$st" in *Complete*|*Failed*) break ;; esac
  sleep 5
done
# 이미 완료된 같은 해시 Job 은 Pod 가 정리됐을 수 있다 → 그때 logs 가 20초 기다리다 'timed out' 을 찍으므로 Pod 가 있을 때만
if kubectl -n $NS get pod -l job-name=$JOB -o name 2>/dev/null | grep -q .; then
  kubectl -n $NS logs job/$JOB --tail=40 || true
fi
case "$st" in
  *Complete*) log "초기화 Job 완료" ;;
  *) kubectl -n $NS describe job $JOB | tail -15; die "초기화 Job 실패 또는 5분 초과 ($st) — 앱 배포 중단" ;;
esac

# ── Service · Gateway (3-7) ────────────────────────
sed "s/__DB_HOST__/$DB_HOST/" k8s/15-services.yaml | kubectl apply -f -
kubectl apply -f k8s/40-gateway.yaml

# readiness gate 는 Pod 생성 시점에 TargetGroupBinding 이 있어야 주입된다 → web 용 TGB 를 기다린다
log "TargetGroupBinding 생성 대기 (ALB 생성 포함 1~3분)"
for _ in $(seq 1 60); do
  n=$(kubectl -n $NS get targetgroupbindings.elbv2.k8s.aws -o name 2>/dev/null | wc -l)
  [ "$n" -ge 1 ] && break
  sleep 5
done
[ "$n" -ge 1 ] || { kubectl -n $NS describe gateway petclinic | tail -20; die "TargetGroupBinding 이 5분 안에 생기지 않음"; }
kubectl -n $NS get targetgroupbindings.elbv2.k8s.aws

# ── Deployment (was → web) ─────────────────────────
ECR=$ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com
: "${IMAGE_TAG:?.state.env 에 IMAGE_TAG 없음 — 60-build-push.sh 먼저}"
log "이미지 태그 $IMAGE_TAG"
sed "s#__IMAGE__#$ECR/pc-was:$IMAGE_TAG#" k8s/20-was.yaml | kubectl apply -f -
kubectl -n $NS rollout status deploy/was --timeout=5m
sed "s#__IMAGE__#$ECR/pc-web:$IMAGE_TAG#" k8s/30-web.yaml | kubectl apply -f -
kubectl -n $NS rollout status deploy/web --timeout=5m

kubectl -n $NS get deploy,hpa,pdb,pod -o wide
ADDR=$(kubectl -n $NS get gateway petclinic -o jsonpath='{.status.addresses[0].value}')
log "ALB 주소: http://$ADDR  (DNS 전파·대상 healthy 까지 1~2분)"
