#!/bin/bash
# 매일 실습 종료 — 앱 0 → 노드 0대 → RDS 중지
# 중지 중에도 나가는 비용: EKS 컨트롤 플레인, NAT GW, ALB, EIP, RDS 스토리지
source "$(dirname "$0")/../env.sh"

for D in web was; do kubectl -n petclinic scale deploy $D --replicas=0 2>/dev/null || true; done
eksctl scale nodegroup --cluster $CLUSTER --name ng-app --nodes 0 --nodes-min 0
aws rds stop-db-instance --db-instance-identifier pc-rds >/dev/null 2>&1 || true   # 7일 뒤 자동 재시작
echo "stopped: $(date)"
