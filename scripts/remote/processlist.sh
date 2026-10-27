#!/bin/bash
# 관리 EC2 에서 실행되는 부분 — 직접 실행하지 않는다. scripts/90-verify.sh conns 가 SSM Run Command 로 보낸다
# V4: 앱 계정(pc_app) 연결 수를 접속 출발지(= was Pod IP)별로 센다. 출력에 비밀번호 없음
set -euo pipefail
export AWS_DEFAULT_REGION=ap-northeast-2
: "${HOST:?}" "${MASTER_ARN:?}"
field() { python3 -c 'import json,sys; print(json.loads(sys.stdin.read())[sys.argv[1]])' "$1"; }
MASTER=$(aws secretsmanager get-secret-value --secret-id "$MASTER_ARN" --query SecretString --output text)
CNF=$(mktemp -p /dev/shm pc-cnf.XXXXXX); chmod 600 "$CNF"
trap 'rm -f "$CNF"' EXIT
printf '[client]\nuser=%s\npassword=%s\nhost=%s\nssl\n' \
  "$(field username <<<"$MASTER")" "$(field password <<<"$MASTER")" "$HOST" > "$CNF"
unset MASTER
date '+%F %T %Z'
mysql --defaults-extra-file="$CNF" -t -e "
  SELECT SUBSTRING_INDEX(host, ':', 1) AS pod_ip, COUNT(*) AS conns
    FROM information_schema.processlist WHERE user = 'pc_app' GROUP BY pod_ip ORDER BY pod_ip;
  SELECT COUNT(*) AS total_pc_app FROM information_schema.processlist WHERE user = 'pc_app';
  SHOW GLOBAL STATUS LIKE 'Max_used_connections';"
