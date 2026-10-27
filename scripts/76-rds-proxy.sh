#!/bin/bash
# 4-4 V6② RDS Proxy — 로컬에서 실행. V6①(직접 연결)과 같은 장애 조치 시험을 Proxy 경유로 다시 해 비교한다
# 사용:
#   bash scripts/76-rds-proxy.sh up       # SG·IAM 역할·Proxy 생성 → 대상(pc-rds) 등록 → 대상 AVAILABLE 대기
#   bash scripts/76-rds-proxy.sh use      # ExternalName db → Proxy 엔드포인트, was 재시작(기존 직접 연결을 버림)
#   bash scripts/76-rds-proxy.sh direct   # 되돌리기: db → RDS 엔드포인트, was 재시작
# 지우기는 destroy.sh (Proxy → 역할 pc-role-rds-proxy → SG pc-sg-proxy). 다시 실행해도 안전하다
#   TLS 필수(--require-tls): 앱 JDBC sslMode=REQUIRED 그대로 Proxy 에 TLS 로 붙는다
#   인증: 3-2 앱 비밀(pc/petclinic/app-db, username·password JSON)만 연결 → Proxy 로는 pc_app 만 들어온다
#   초기화 Job·bootstrap 은 계속 RDS 직접(60-db-init-job.yaml) — 앱 경로만 바꾼다
set -euo pipefail
source "$(dirname "$0")/../env.sh"
cd "$PC_HOME"
PROXY=pc-proxy
ROLE=pc-role-rds-proxy

ensure_sg() {  # 변수명 이름 설명 — 10-network.sh 와 같은 함수
  local id; id=$(ec2_id sg $2)
  [ -n "$id" ] || id=$(aws ec2 create-security-group --vpc-id $VPC_ID --group-name $2 --description "$3" \
    --tag-specifications "$(tagspec security-group $2)" --query GroupId --output text)
  printf -v "$1" %s "$id"; save "$1"
}
proxy_ep() { aws rds describe-db-proxies --db-proxy-name $PROXY --query 'DBProxies[0].Endpoint' --output text; }

switch_db() {  # 새 externalName — ExternalName db 를 바꾸고 was 를 다시 띄워 풀의 기존 연결을 버린다
  tunnel_up
  kubectl -n $NS patch svc db --type merge -p "{\"spec\":{\"externalName\":\"$1\"}}"
  kubectl -n $NS rollout restart deploy/was
  kubectl -n $NS rollout status deploy/was --timeout=5m
  kubectl -n $NS get svc db -o jsonpath='db → {.spec.externalName}{"\n"}'
  ADDR=$(kubectl -n $NS get gateway petclinic -o jsonpath='{.status.addresses[0].value}')
  log "확인: $(curl -s -o /dev/null -w '%{http_code}' "http://$ADDR/owners?lastName=") (/owners = was → db 경로)"
}

case ${1:-} in
up)
  require_aws 30
  # ── SG: 노드 → Proxy 3306, Proxy → RDS 3306 (RDS 는 노드·관리 EC2·Proxy 에서만) ──
  ensure_sg SG_PROXY pc-sg-proxy "RDS Proxy - 3306 from nodes only"
  allow_sg $SG_PROXY 3306 $SG_NODE "nodes (was pods) to RDS Proxy"
  allow_sg $SG_RDS 3306 $SG_PROXY "RDS Proxy to RDS"

  # ── IAM: Proxy 가 앱 비밀 하나만 읽는 역할 ──
  APP_ARN=$(aws secretsmanager describe-secret --secret-id pc/petclinic/app-db --query ARN --output text)
  if ! aws iam get-role --role-name $ROLE >/dev/null 2>&1; then
    aws iam create-role --role-name $ROLE --tags $(tags_kv) --assume-role-policy-document '{
      "Version":"2012-10-17",
      "Statement":[{"Effect":"Allow","Principal":{"Service":"rds.amazonaws.com"},"Action":"sts:AssumeRole"}]}' >/dev/null
    log "IAM 역할 $ROLE 생성"
  fi
  # 비밀은 AWS 관리형 키(aws/secretsmanager)로 암호화 → 복호화는 Secrets Manager 를 거칠 때만
  aws iam put-role-policy --role-name $ROLE --policy-name pc-proxy-read-app-db --policy-document "{
    \"Version\":\"2012-10-17\",
    \"Statement\":[
      {\"Effect\":\"Allow\",\"Action\":[\"secretsmanager:GetSecretValue\",\"secretsmanager:DescribeSecret\"],\"Resource\":\"$APP_ARN\"},
      {\"Effect\":\"Allow\",\"Action\":\"kms:Decrypt\",\"Resource\":\"*\",
       \"Condition\":{\"StringEquals\":{\"kms:ViaService\":\"secretsmanager.$AWS_REGION.amazonaws.com\"}}}]}"
  log "✔ $ROLE: 앱 비밀 1개만 읽기"

  # ── Proxy ──
  if ! aws rds describe-db-proxies --db-proxy-name $PROXY >/dev/null 2>&1; then
    # 역할을 막 만들었으면 IAM 전파 전에 create 가 거부될 수 있다 → 몇 번 다시 시도
    for i in 1 2 3 4 5 6; do
      if err=$(aws rds create-db-proxy --db-proxy-name $PROXY --engine-family MYSQL \
            --auth "AuthScheme=SECRETS,SecretArn=$APP_ARN,IAMAuth=DISABLED,ClientPasswordAuthType=MYSQL_CACHING_SHA2_PASSWORD" \
            --role-arn arn:aws:iam::$ACCOUNT_ID:role/$ROLE \
            --vpc-subnet-ids $SUBNET_DB_A $SUBNET_DB_C --vpc-security-group-ids $SG_PROXY \
            --require-tls --idle-client-timeout 1800 \
            --tags $(tags_kv) Key=Name,Value=$PROXY 2>&1 >/dev/null); then
        log "Proxy $PROXY 생성 시작"; break
      fi
      [ $i = 6 ] && die "$err"
      log "Proxy 생성 재시도 ($i/6): ${err##*: }"; sleep 10
    done
  fi
  log "Proxy available 대기 (보통 5~15분)"
  for _ in $(seq 1 120); do
    st=$(aws rds describe-db-proxies --db-proxy-name $PROXY --query 'DBProxies[0].Status' --output text)
    [ "$st" = available ] && break; sleep 15
  done
  [ "$st" = available ] || die "Proxy 상태 $st (30분 초과)"

  # ── 대상: pc-rds (Multi-AZ 인스턴스 하나 — 장애 조치는 Proxy 가 따라간다) ──
  n=$(aws rds describe-db-proxy-targets --db-proxy-name $PROXY --query 'length(Targets)' --output text 2>/dev/null || echo 0)
  [ "$n" -gt 0 ] || aws rds register-db-proxy-targets --db-proxy-name $PROXY --db-instance-identifiers $RDS_ID >/dev/null
  log "대상 AVAILABLE 대기 (몇 분)"
  for _ in $(seq 1 60); do
    th=$(aws rds describe-db-proxy-targets --db-proxy-name $PROXY \
           --query "Targets[?Type=='RDS_INSTANCE'].TargetHealth.State | [0]" --output text)
    [ "$th" = AVAILABLE ] && break; sleep 10
  done
  aws rds describe-db-proxy-targets --db-proxy-name $PROXY \
    --query "Targets[].[Type,RdsResourceId,TargetHealth.State,TargetHealth.Reason]" --output table
  [ "$th" = AVAILABLE ] || die "대상 상태 $th — 위 Reason 확인 (인증 실패면 비밀·역할, 연결 실패면 SG)"
  echo "== 증빙 📸"
  aws rds describe-db-proxies --db-proxy-name $PROXY \
    --query 'DBProxies[0].{name:DBProxyName,status:Status,engine:EngineFamily,requireTLS:RequireTLS,endpoint:Endpoint,subnets:VpcSubnetIds}' --output json
  log "다음: bash scripts/76-rds-proxy.sh use" ;;

use)
  require_aws 10
  EP=$(proxy_ep); [ -n "$EP" ] && [ "$EP" != None ] || die "Proxy 없음 — up 먼저"
  switch_db "$EP" ;;

direct)
  require_aws 10
  switch_db "$(aws rds describe-db-instances --db-instance-identifier $RDS_ID --query 'DBInstances[0].Endpoint.Address' --output text)" ;;

*) sed -n 3,6p "$0"; exit 1 ;;
esac
