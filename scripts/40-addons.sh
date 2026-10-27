#!/bin/bash
# 클러스터 애드온 — Gateway API CRD v1.6.0 · LBC(Helm 3.5.0) · metrics-server(EKS 애드온, 확인만)
# LBC 의 IAM 역할은 cluster.yaml 의 podIdentityAssociations 가 이미 연결했다 (IRSA 아님)
# 순서: 30-cluster.sh 가 엔드포인트를 프라이빗 전용으로 닫은 "뒤"에 실행한다
#   → 쿠버네티스 API 는 로컬이면 터널(tunnel_up 이 자동으로 엶), 관리 EC2 면 PC_KUBE_DIRECT=1
set -euo pipefail
source "$(dirname "$0")/../env.sh"
require_aws 20
tunnel_up

# ── Gateway API 표준 CRD ─────────────────────────────
kubectl apply --server-side -f \
  https://github.com/kubernetes-sigs/gateway-api/releases/download/$GATEWAY_API_VERSION/standard-install.yaml

# ── LBC 전용 Gateway CRD (LoadBalancerConfiguration 등) — main 이 아니라 태그 경로로 고정 ──
# v3.5.0 태그에 이 경로가 있음을 확인함 (2026-10-22, HTTP 200)
kubectl apply --server-side -f \
  https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/$LBC_VERSION/config/crd/gateway/gateway-crds.yaml

# ── LBC (Helm) ──────────────────────────────────────
helm repo add eks https://aws.github.io/eks-charts >/dev/null 2>&1 || true
helm repo update eks >/dev/null
# ALBGatewayAPI 기능 게이트는 v3.5.0 기본값 true (pkg/config/feature_gates.go) → 따로 켜지 않는다
# region·vpcId 는 필수 — 노드가 disablePodIMDS(hop limit 1)라 LBC 가 IMDS 로 스스로 찾지 못한다
helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system --version $LBC_CHART_VERSION \
  --set clusterName=$CLUSTER \
  --set region=$AWS_REGION \
  --set vpcId=$VPC_ID \
  --set serviceAccount.create=true \
  --set serviceAccount.name=aws-load-balancer-controller \
  --wait --timeout 5m

# ── metrics-server — eksctl 이 EKS 관리형 애드온으로 설치함(30-cluster.sh). 매니페스트로 덮어쓰지 않는다 ──
kubectl rollout status deploy/metrics-server -n kube-system --timeout=180s

kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller
log "애드온 완료 — 확인: kubectl top nodes"
