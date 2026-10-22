#!/bin/bash
# RDS MySQL 8.4 — private-db a·c, Multi-AZ, 삭제 방지·백업 7일·저장 암호화·전송 TLS 강제 (기획서 2.3)
# master 비밀번호는 스크립트가 만들지 않는다 → RDS 가 Secrets Manager 에 직접 관리(--manage-master-user-password)
# 생성에 20~30분 걸리므로 기다리지 않고 끝낸다. 다른 작업과 병렬로 진행 (작업지시서 2-3)
set -euo pipefail
source "$(dirname "$0")/../env.sh"
require_aws 15

if ! aws rds describe-db-subnet-groups --db-subnet-group-name pc-dbsubnet >/dev/null 2>&1; then
  aws rds create-db-subnet-group --db-subnet-group-name pc-dbsubnet \
    --db-subnet-group-description "petclinic RDS - private-db a,c" \
    --subnet-ids $SUBNET_DB_A $SUBNET_DB_C --tags $(tags_kv) >/dev/null
fi

# 사용자 파라미터 그룹 — 기본 그룹은 수정할 수 없으므로 생성 시점에 붙여야 한다
# require_secure_transport=1: TLS 없는 접속을 서버가 거부 (앱 JDBC sslMode=REQUIRED, mysql 클라이언트 --ssl-mode=REQUIRED)
PG=pc-mysql84
if ! aws rds describe-db-parameter-groups --db-parameter-group-name $PG >/dev/null 2>&1; then
  aws rds create-db-parameter-group --db-parameter-group-name $PG --db-parameter-group-family mysql8.4 \
    --description "petclinic - TLS required" --tags $(tags_kv) >/dev/null
fi
aws rds modify-db-parameter-group --db-parameter-group-name $PG \
  --parameters "ParameterName=require_secure_transport,ParameterValue=1,ApplyMethod=immediate" >/dev/null

if aws rds describe-db-instances --db-instance-identifier $RDS_ID >/dev/null 2>&1; then
  log "RDS $RDS_ID 이미 있음 — 상태: $(aws rds describe-db-instances --db-instance-identifier $RDS_ID \
    --query 'DBInstances[0].DBInstanceStatus' --output text)"
else
  aws rds create-db-instance --db-instance-identifier $RDS_ID \
    --engine mysql --engine-version $RDS_ENGINE_VERSION --db-instance-class $RDS_CLASS \
    --allocated-storage $RDS_STORAGE_GB --storage-type gp3 --storage-encrypted \
    --multi-az --db-subnet-group-name pc-dbsubnet --vpc-security-group-ids $SG_RDS \
    --db-parameter-group-name $PG \
    --no-publicly-accessible \
    --db-name $DB_NAME --master-username pcadmin --manage-master-user-password \
    --backup-retention-period 7 --copy-tags-to-snapshot --deletion-protection \
    --tags Key=Name,Value=$RDS_ID $(tags_kv) >/dev/null
  log "RDS $RDS_ID 생성 시작 (20~30분). 완료 확인: aws rds wait db-instance-available --db-instance-identifier $RDS_ID"
fi

cat <<'EOF'
다음 (available 이 된 뒤, 관리 EC2 SSM 세션에서):
  max_connections 실측 — 기획서 2.3 단서. 53 + 여유보다 작으면 DB_POOL_MAX 를 낮춘다
    mysql --ssl-mode=REQUIRED -h <RDS 엔드포인트> -u pcadmin -p -e "SHOW VARIABLES LIKE 'max_connections';"
  TLS 강제 확인 — 같은 명령을 --ssl-mode=DISABLED 로 바꾸면 접속이 거부되어야 한다 📸
  master 비밀번호는 Secrets Manager 의 RDS 관리형 비밀(rds!db-...)에서 읽는다 — 채팅·파일에 남기지 않음
EOF
