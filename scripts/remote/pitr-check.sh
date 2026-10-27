#!/bin/bash
# 관리 EC2 에서 실행되는 부분 — 직접 실행하지 않는다. scripts/77-pitr.sh check 가 SSM Run Command 로 보낸다
# PROD(운영 RDS)·PITR(복원 인스턴스, 없으면 빈 값) 은 보내는 쪽이 앞에 붙여 준다
# 앱 계정(pc_app, SELECT 권한)으로만 읽는다 — 복원본에도 같은 계정이 들어 있다(사용자 테이블도 시점 복원 대상)
set -euo pipefail
export AWS_DEFAULT_REGION=ap-northeast-2
: "${PROD:?}"

APP=$(aws secretsmanager get-secret-value --secret-id pc/petclinic/app-db --query SecretString --output text)
field() { python3 -c 'import json,sys; print(json.loads(sys.stdin.read())[sys.argv[1]])' "$1"; }
CNF=$(mktemp -p /dev/shm pc-cnf.XXXXXX); chmod 600 "$CNF"
trap 'rm -f "$CNF"' EXIT
printf '[client]\nuser=%s\npassword=%s\nssl\n' "$(field username <<<"$APP")" "$(field password <<<"$APP")" > "$CNF"
unset APP

for h in PROD PITR; do
  [ -n "${!h:-}" ] || continue
  echo "== $h (${!h%%.*})"
  mysql --defaults-extra-file="$CNF" -h "${!h}" -t petclinic <<'SQL'
SELECT (SELECT COUNT(*) FROM owners) AS owners, (SELECT MAX(id) FROM owners) AS max_owner_id,
       (SELECT COUNT(*) FROM pets) AS pets, (SELECT COUNT(*) FROM visits) AS visits;
SELECT id, last_name, city FROM owners ORDER BY id DESC LIMIT 3;
SQL
done
