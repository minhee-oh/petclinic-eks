#!/bin/bash
# 3-3 DB 계정 부트스트랩 — 로컬에서 실행. 실제 SQL 은 관리 EC2 가 SSM Run Command 로 실행한다(scripts/remote/db-bootstrap.sh)
#   SSM 세션에 긴 스크립트를 붙여 넣으면 줄이 잘려 깨진다(10/25 실측) → 파일 내용을 명령 파라미터로 보낸다
#   RDS 엔드포인트·master 비밀 ARN 은 여기서 조회해 앞에 붙인다 → 관리 EC2 역할은 비밀 3개 읽기만 있으면 된다
# 다시 실행해도 안전하다 (비밀번호를 비밀 값으로 다시 맞춤). 출력에 비밀번호는 없다
set -euo pipefail
source "$(dirname "$0")/../env.sh"
require_aws 10
cd "$PC_HOME"   # 아래 file:// 상대 경로 기준

read -r HOST MASTER_ARN < <(aws rds describe-db-instances --db-instance-identifier $RDS_ID \
  --query 'DBInstances[0].[Endpoint.Address,MasterUserSecret.SecretArn]' --output text)

# AWS CLI 는 Windows 프로그램이라 /tmp 를 못 읽는다 → 저장소 안 임시 파일(.gitignore 등록)
# AWS-RunShellScript 는 sh 로 돌리므로, 원격 스크립트를 파일로 쓴 뒤 bash 로 실행한다
PARAMS=.ssm-params.json
trap 'rm -f "$PARAMS"' EXIT
{ echo "cat > /root/pc-db-bootstrap.sh <<'PC_EOF'"
  printf 'export HOST=%q MASTER_ARN=%q\n' "$HOST" "$MASTER_ARN"
  tr -d '\r' < scripts/remote/db-bootstrap.sh
  echo "PC_EOF"
  echo "bash /root/pc-db-bootstrap.sh; rc=\$?; rm -f /root/pc-db-bootstrap.sh; exit \$rc"
} | jq -a -Rs '{commands: [.]}' > "$PARAMS"   # -a: 한글 주석을 \uXXXX 로 — Windows AWS CLI 는 파일을 cp949 로 읽어 UTF-8 이 깨진다

CMD_ID=$(aws ssm send-command --instance-ids $MGMT_ID --document-name AWS-RunShellScript \
  --comment "pc 3-3 db bootstrap" --parameters file://.ssm-params.json \
  --query Command.CommandId --output text)
log "SSM 명령 $CMD_ID 전송 — 완료 대기"
aws ssm wait command-executed --command-id $CMD_ID --instance-id $MGMT_ID || true

aws ssm get-command-invocation --command-id $CMD_ID --instance-id $MGMT_ID \
  --query '[Status,StandardOutputContent,StandardErrorContent]' --output text
