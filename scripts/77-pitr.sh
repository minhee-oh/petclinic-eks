#!/bin/bash
# RDS PITR 복구 리허설 (작업지시서 4-5 선택) — 로컬에서 실행
# "백업 7일" 설정이 실제로 복구되는지: 시점 T 를 찍고 → T 뒤에 데이터를 바꾸고 → T 로 새 인스턴스 복원 → 복원본에는 T 뒤 변경이 없어야 한다
# 사용:
#   bash scripts/77-pitr.sh mark      # 지금 시각(UTC)을 T 로 저장 + 운영 DB 행 수 기록 → 그 뒤 브라우저로 주인 1명 등록
#   bash scripts/77-pitr.sh restore   # T 로 pc-rds-pitr 복원 시작 (T 가 복원 가능 시각 안에 들어올 때까지 기다림) → available 대기
#   bash scripts/77-pitr.sh check     # 운영·복원본 행 수 비교 (관리 EC2 → SSM, 앱 계정으로 SELECT)
#   bash scripts/77-pitr.sh delete    # 복원본 삭제 (최종 스냅샷·자동 백업 없이) → 삭제 완료 대기
# 복원본: 단일 AZ, 운영과 같은 서브넷 그룹·SG·파라미터 그룹(TLS 강제), 삭제 방지 끔. destroy.sh 도 남아 있으면 지운다
set -euo pipefail
source "$(dirname "$0")/../env.sh"
cd "$PC_HOME"
PITR_ID=pc-rds-pitr

addr() { aws rds describe-db-instances --db-instance-identifier "$1" --query 'DBInstances[0].Endpoint.Address' --output text 2>/dev/null || true; }

check() {
  local prod pitr PARAMS=.ssm-params.json   # 저장소 안 임시 파일(.gitignore) — Windows AWS CLI 는 /tmp 를 못 읽는다
  prod=$(addr $RDS_ID); pitr=$(addr $PITR_ID); [ "$pitr" = None ] && pitr=""
  { echo "cat > /root/pc-pitr-check.sh <<'PC_EOF'"
    printf 'export PROD=%q PITR=%q\n' "$prod" "$pitr"
    tr -d '\r' < scripts/remote/pitr-check.sh
    echo "PC_EOF"
    echo "bash /root/pc-pitr-check.sh; rc=\$?; rm -f /root/pc-pitr-check.sh; exit \$rc"
  } | jq -a -Rs '{commands: [.]}' > "$PARAMS"   # -a: cp949 문제(3-3)
  local id
  id=$(aws ssm send-command --instance-ids $MGMT_ID --document-name AWS-RunShellScript \
    --comment "pc pitr check" --parameters file://$PARAMS --query Command.CommandId --output text)
  rm -f "$PARAMS"
  aws ssm wait command-executed --command-id $id --instance-id $MGMT_ID || true
  aws ssm get-command-invocation --command-id $id --instance-id $MGMT_ID \
    --query '[Status,StandardOutputContent,StandardErrorContent]' --output text
}

case ${1:-} in
mark)
  require_aws 10
  PITR_MARK=$(date -u +%Y-%m-%dT%H:%M:%SZ); save PITR_MARK
  log "T = $PITR_MARK (UTC) = $(date '+%H:%M:%S') KST — 운영 DB 현재 행 수:"
  check
  log "다음: 브라우저에서 주인 1명 등록(T 뒤 변경) → 5분쯤 뒤 restore (복원 가능 시각이 T 를 넘어야 함)" ;;

restore)
  require_aws 40
  : "${PITR_MARK:?mark 먼저}"
  if aws rds describe-db-instances --db-instance-identifier $PITR_ID >/dev/null 2>&1; then
    log "$PITR_ID 이미 있음 — 상태 확인으로 넘어감"
  else
    log "복원 가능 시각이 T($PITR_MARK)를 넘을 때까지 대기 (트랜잭션 로그 업로드 주기 약 5분)"
    for _ in $(seq 1 40); do
      latest=$(aws rds describe-db-instances --db-instance-identifier $RDS_ID --query 'DBInstances[0].LatestRestorableTime' --output text)
      [ "$(date -u -d "$latest" +%s)" -ge "$(date -u -d "$PITR_MARK" +%s)" ] && break; sleep 15
    done
    log "LatestRestorableTime $latest"
    aws rds restore-db-instance-to-point-in-time --source-db-instance-identifier $RDS_ID \
      --target-db-instance-identifier $PITR_ID --restore-time "$PITR_MARK" \
      --db-instance-class $RDS_CLASS --no-multi-az --db-subnet-group-name pc-dbsubnet \
      --vpc-security-group-ids $SG_RDS --db-parameter-group-name pc-mysql84 \
      --no-publicly-accessible --no-deletion-protection \
      --tags Key=Name,Value=$PITR_ID $(tags_kv) >/dev/null
    PITR_START=$(date +%s); save PITR_START
    log "복원 요청 ($PITR_ID ← $RDS_ID @ $PITR_MARK)"
  fi
  log "available 대기 (보통 15~30분)"
  for _ in $(seq 1 180); do
    st=$(aws rds describe-db-instances --db-instance-identifier $PITR_ID --query 'DBInstances[0].DBInstanceStatus' --output text)
    [ "$st" = available ] && break; sleep 20
  done
  [ "$st" = available ] || die "$PITR_ID 상태 $st (1시간 초과)"
  log "✔ $PITR_ID available — 요청부터 $(( ($(date +%s) - ${PITR_START:-$(date +%s)}) / 60 ))분"
  aws rds describe-db-instances --db-instance-identifier $PITR_ID \
    --query 'DBInstances[0].{id:DBInstanceIdentifier,status:DBInstanceStatus,multiAZ:MultiAZ,az:AvailabilityZone,encrypted:StorageEncrypted,created:InstanceCreateTime}' --output table
  log "다음: bash scripts/77-pitr.sh check" ;;

check)
  require_aws 5
  log "T = ${PITR_MARK:-(없음)} UTC — 복원본은 T 시점, 운영은 지금"
  check ;;

delete)
  require_aws 30
  if aws rds describe-db-instances --db-instance-identifier $PITR_ID >/dev/null 2>&1; then
    aws rds delete-db-instance --db-instance-identifier $PITR_ID --skip-final-snapshot --delete-automated-backups >/dev/null \
      || log "삭제 요청 실패 또는 이미 삭제 중"
    log "$PITR_ID 삭제 대기 (5~10분)"
    aws rds wait db-instance-deleted --db-instance-identifier $PITR_ID
  fi
  log "✔ $PITR_ID 없음" ;;

*) sed -n 4,8p "$0"; exit 1 ;;
esac
