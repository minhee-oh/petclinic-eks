#!/bin/bash
# 로컬 kubectl → SSM 포트 포워딩(localhost:8443) → 관리 EC2 → EKS 프라이빗 엔드포인트 443
# 이 창을 열어 둔 동안만 kubectl 이 동작한다. 끝내려면 Ctrl+C.
# 최초 1회 준비(🔒 승인 필요, 작업지시서 2-6):
#   1) Session Manager 플러그인 설치
#   2) hosts 파일(C:\Windows\System32\drivers\etc\hosts)에 아래 출력되는 한 줄 추가 — 인증서가 엔드포인트 이름으로 발급돼서
set -euo pipefail
source "$(dirname "$0")/../env.sh"
require_aws 15
command -v session-manager-plugin >/dev/null || die "Session Manager 플러그인 없음"

EP=$(aws eks describe-cluster --name $CLUSTER --query cluster.endpoint --output text)
HOST=${EP#https://}

# kubeconfig: 이름은 그대로, 포트만 8443 (hosts 가 그 이름을 127.0.0.1 로 돌린다)
aws eks update-kubeconfig --name $CLUSTER --alias $CLUSTER >/dev/null
kubectl config set-cluster "$(kubectl config view -o jsonpath="{.contexts[?(@.name=='$CLUSTER')].context.cluster}")" \
  --server "https://$HOST:8443" >/dev/null

if ! grep -q "$HOST" /c/Windows/System32/drivers/etc/hosts 2>/dev/null; then
  echo "hosts 파일에 이 줄이 없습니다 (관리자 권한으로 추가):"
  echo "127.0.0.1 $HOST"
  exit 1
fi

log "터널 시작 — 다른 창에서 kubectl get nodes"
exec aws ssm start-session --target $MGMT_ID \
  --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters "host=$HOST,portNumber=443,localPortNumber=8443"
