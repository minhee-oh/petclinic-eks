#!/bin/bash
# 다음 날 재개 — RDS 시작 → 노드 2대 → 앱 복구
source "$(dirname "$0")/../env.sh"

HAS_RDS=$(aws rds describe-db-instances --db-instance-identifier pc-rds >/dev/null 2>&1 && echo yes)
[ "$HAS_RDS" = yes ] && aws rds start-db-instance --db-instance-identifier pc-rds >/dev/null 2>&1
eksctl scale nodegroup --cluster $CLUSTER --name ng-app --nodes 2 --nodes-min 0 --nodes-max 4
kubectl wait --for=condition=Ready nodes -l pc/role=app --timeout=10m
[ "$HAS_RDS" = yes ] && aws rds wait db-instance-available --db-instance-identifier pc-rds

# 앱이 배포된 뒤(3일차~)에만 의미 있음
kubectl -n petclinic scale deploy was --replicas=2 2>/dev/null || true
kubectl -n petclinic scale deploy web --replicas=2 2>/dev/null || true
kubectl -n petclinic rollout status deploy/was --timeout=15m 2>/dev/null || true
kubectl -n petclinic rollout status deploy/web 2>/dev/null || true
[ -n "$ALB_DNS" ] && curl -s -o /dev/null -w 'healthz %{http_code}\n' http://$ALB_DNS/healthz || true
