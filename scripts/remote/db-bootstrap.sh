#!/bin/bash
# 관리 EC2 에서 실행되는 부분 — 직접 실행하지 않는다. scripts/32-db-bootstrap.sh 가 SSM Run Command 로 보낸다
# HOST·MASTER_ARN 은 보내는 쪽(로컬)이 앞에 붙여 준다 → 관리 EC2 역할에 rds:Describe* 권한이 필요 없다
#   pc_app       : petclinic.* DML 만 (앱)
#   pc_migration : petclinic.* DDL + DML (초기화 Job)
# 비밀번호는 Secrets Manager 에서 읽어 stdin 으로만 넘긴다 — 명령줄·파일·출력에 남기지 않음
# 관리 EC2 는 MariaDB 클라이언트 10.5 → --ssl-mode 대신 [client] ssl (서버가 require_secure_transport=1)
set -euo pipefail
export AWS_DEFAULT_REGION=ap-northeast-2
DB=petclinic
: "${HOST:?}" "${MASTER_ARN:?}"

secret_json() { aws secretsmanager get-secret-value --secret-id "$1" --query SecretString --output text; }
field() { python3 -c 'import json,sys; print(json.loads(sys.stdin.read())[sys.argv[1]])' "$1"; }

MASTER=$(secret_json "$MASTER_ARN")
APP=$(secret_json pc/petclinic/app-db)
MIG=$(secret_json pc/petclinic/migration-db)

# master 접속 정보는 권한 600 임시 파일로만 (메모리 파일시스템)
CNF=$(mktemp -p /dev/shm pc-cnf.XXXXXX); chmod 600 "$CNF"
trap 'rm -f "$CNF"' EXIT
printf '[client]\nuser=%s\npassword=%s\nhost=%s\nssl\n' \
  "$(field username <<<"$MASTER")" "$(field password <<<"$MASTER")" "$HOST" > "$CNF"

APP_USER=$(field username <<<"$APP");  APP_PW=$(field password <<<"$APP")
MIG_USER=$(field username <<<"$MIG");  MIG_PW=$(field password <<<"$MIG")
unset MASTER APP MIG

# 비밀번호는 --exclude-punctuation 으로 만들어 따옴표가 없다 → SQL 문자열에 그대로 넣어도 안전
mysql --defaults-extra-file="$CNF" <<SQL
CREATE DATABASE IF NOT EXISTS \`$DB\`;
CREATE USER IF NOT EXISTS '$APP_USER'@'%' IDENTIFIED BY '$APP_PW' REQUIRE SSL;
ALTER USER '$APP_USER'@'%' IDENTIFIED BY '$APP_PW' REQUIRE SSL;
GRANT SELECT, INSERT, UPDATE, DELETE ON \`$DB\`.* TO '$APP_USER'@'%';
CREATE USER IF NOT EXISTS '$MIG_USER'@'%' IDENTIFIED BY '$MIG_PW' REQUIRE SSL;
ALTER USER '$MIG_USER'@'%' IDENTIFIED BY '$MIG_PW' REQUIRE SSL;
GRANT CREATE, ALTER, DROP, INDEX, REFERENCES, SELECT, INSERT, UPDATE, DELETE ON \`$DB\`.* TO '$MIG_USER'@'%';
SQL
unset APP_PW MIG_PW

echo "== grants"   # 출력은 Windows AWS CLI 가 cp949 로 보여 줘서 한글이 깨진다 → 영문
mysql --defaults-extra-file="$CNF" -t <<SQL
SHOW GRANTS FOR '$APP_USER'@'%';
SHOW GRANTS FOR '$MIG_USER'@'%';
SELECT user, host, ssl_type FROM mysql.user WHERE user IN ('$APP_USER','$MIG_USER');
SQL
