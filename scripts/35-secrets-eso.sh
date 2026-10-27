#!/bin/bash
# 재구축(10/26 카나리용)에서 손으로 하던 단계를 한 번에 — 로컬에서 실행. 40-addons.sh 뒤, 32-db-bootstrap.sh 앞
#   ① DB 비밀 2개: destroy 가 7일 복구 기간으로 지웠으면 되살린다 (같은 이름은 그동안 새로 만들 수 없음, 값은 그대로)
#   ② 관리 EC2 역할에 비밀 읽기 권한: 앱 비밀 2개 + 새 RDS 의 master 비밀 (RDS 를 새로 만들면 master 비밀 ARN 이 바뀜)
#   ③ GatewayClass pc-alb (처음엔 2-8 샘플 파일로 만들었던 것)
#   ④ ESO Helm (3-3 에서 손으로 설치 — 버전은 덤프 E2 의 v2.12.0 그대로)
# 다시 실행해도 안전하다
set -euo pipefail
source "$(dirname "$0")/../env.sh"
require_aws 20
cd "$PC_HOME"
ESO_VERSION=2.12.0

# ① 비밀
for s in pc/petclinic/app-db pc/petclinic/migration-db; do
  del=$(aws secretsmanager describe-secret --secret-id $s --query DeletedDate --output text 2>/dev/null) \
    || die "비밀 $s 없음 — 작업지시서 3-2 대로 새로 만든 뒤 다시 실행"
  if [ "$del" != None ]; then aws secretsmanager restore-secret --secret-id $s >/dev/null; log "✔ 비밀 $s 복구"
  else log "비밀 $s 있음"; fi
done

# ② 관리 EC2 역할 — RDS 가 master 비밀을 만든 뒤여야 한다
log "RDS available 대기 (31-rds.sh 를 먼저 시작했어야 함)"
aws rds wait db-instance-available --db-instance-identifier $RDS_ID
MASTER_ARN=$(aws rds describe-db-instances --db-instance-identifier $RDS_ID \
  --query 'DBInstances[0].MasterUserSecret.SecretArn' --output text)
SM=arn:aws:secretsmanager:$AWS_REGION:$ACCOUNT_ID:secret
aws iam put-role-policy --role-name pc-role-mgmt --policy-name pc-read-db-secrets --policy-document "{
  \"Version\": \"2012-10-17\",
  \"Statement\": [{
    \"Sid\": \"ReadDbSecretsForBootstrap\",
    \"Effect\": \"Allow\",
    \"Action\": [\"secretsmanager:GetSecretValue\", \"secretsmanager:DescribeSecret\"],
    \"Resource\": [\"$SM:pc/petclinic/app-db-*\", \"$SM:pc/petclinic/migration-db-*\", \"$MASTER_ARN\"]
  }]
}"
log "✔ pc-role-mgmt 비밀 읽기 (앱 2개 + master)"

# ③·④ 클러스터
tunnel_up
kubectl apply -f - <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: pc-alb
spec:
  controllerName: gateway.k8s.aws/alb
EOF
helm repo add external-secrets https://charts.external-secrets.io >/dev/null 2>&1 || true
helm repo update external-secrets >/dev/null
helm upgrade --install external-secrets external-secrets/external-secrets -n external-secrets --create-namespace \
  --version $ESO_VERSION --wait --timeout 5m
kubectl -n external-secrets get deploy
log "다음: bash scripts/32-db-bootstrap.sh"
