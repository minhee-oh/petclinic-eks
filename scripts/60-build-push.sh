#!/bin/bash
# 3-5 이미지 빌드·Trivy·ECR push — 로컬에서 실행. 실제 빌드는 관리 EC2(Docker)가 SSM Run Command 로 한다
#   로컬에는 Docker·Maven·Trivy 가 없다(기획서). SSM 세션 붙여 넣기는 줄이 잘려 쓰지 않는다(3-3 트러블슈팅)
#   빌드 컨텍스트(docker/web·was)는 base64 로 명령에 실어 보낸다 — 관리 EC2 에 저장소를 둘 필요가 없다
# 사용: bash scripts/60-build-push.sh                 (태그 기본값 1.0.0-<앱 커밋 7자리>)
#       IMAGE_TAG=1.0.1-xxxx bash scripts/60-build-push.sh   (다시 빌드 — 태그 변경 불가라 새 태그 필요)
set -euo pipefail
REQ_TAG=${IMAGE_TAG:-}   # env.sh 가 .state.env 의 지난 IMAGE_TAG 를 불러와 덮어쓰므로 먼저 받아 둔다
source "$(dirname "$0")/../env.sh"
require_aws 60
cd "$PC_HOME"

ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
ECR=$ACCOUNT.dkr.ecr.$AWS_REGION.amazonaws.com
APP_REF=${APP_REF:-main}
APP_SHA=$(git ls-remote https://github.com/spring-petclinic/spring-framework-petclinic.git "$APP_REF" | cut -c1-40)
[ -n "$APP_SHA" ] || die "앱 커밋을 찾지 못함: $APP_REF"
IMAGE_TAG=${REQ_TAG:-1.0.0-${APP_SHA:0:7}}
TRIVY_IMAGE=public.ecr.aws/aquasecurity/trivy:0.75.0   # 2026-10-01 — 최신(0.76.x)은 2주 미만이라 제외
MAVEN_IMAGE=maven:3.9-eclipse-temurin-21               # pom 은 Java 17 이상 요구
MYSQL_DRIVER=26.7.0   # com.mysql:mysql-connector-j 2026-07-24 — 원본 pom 의 8.1.0 은 없는 버전(3-5 트러블슈팅), 26.10.0 은 2주 미만
log "앱 커밋 $APP_SHA → 태그 $IMAGE_TAG"

b64() { tr -d '\r' < "$1" | base64 -w0; }
PARAMS=.ssm-params.json
trap 'rm -f "$PARAMS"' EXIT
{ echo "cat > /root/pc-build-push.sh <<'PC_EOF'"
  printf 'export ECR=%q IMAGE_TAG=%q APP_REF=%q TRIVY_IMAGE=%q MAVEN_IMAGE=%q MYSQL_DRIVER=%q WEB_BASE=%q\n' \
    "$ECR" "$IMAGE_TAG" "$APP_SHA" "$TRIVY_IMAGE" "$MAVEN_IMAGE" "$MYSQL_DRIVER" "${WEB_BASE:-}"
  printf 'export CTX_WEB_DOCKERFILE=%s\n' "$(b64 docker/web/Dockerfile)"
  printf 'export CTX_WEB_TEMPLATE=%s\n'   "$(b64 docker/web/default.conf.template)"
  printf 'export CTX_WAS_DOCKERFILE=%s\n' "$(b64 docker/was/Dockerfile)"
  printf 'export CTX_WAS_ENTRYPOINT=%s\n' "$(b64 docker/was/pc-entrypoint.sh)"
  tr -d '\r' < scripts/remote/build-push.sh
  echo "PC_EOF"
  echo "bash /root/pc-build-push.sh 2>&1; rc=\$?; rm -f /root/pc-build-push.sh; exit \$rc"
} | jq -a -Rs '{commands: [.], executionTimeout: ["3600"]}' > "$PARAMS"   # -a: cp949 문제(3-3)

CMD_ID=$(aws ssm send-command --instance-ids $MGMT_ID --document-name AWS-RunShellScript \
  --comment "pc 3-5 build-push $IMAGE_TAG" --timeout-seconds 600 --parameters file://$PARAMS \
  --query Command.CommandId --output text)
log "SSM 명령 $CMD_ID 전송 — 빌드 대기 (첫 빌드는 Maven 의존성 때문에 5~10분)"

# aws ssm wait 는 약 100초면 포기하므로 직접 기다린다
for _ in $(seq 1 160); do
  st=$(aws ssm get-command-invocation --command-id $CMD_ID --instance-id $MGMT_ID --query Status --output text 2>/dev/null || echo Pending)
  case $st in Pending|InProgress|Delayed) sleep 15 ;; *) break ;; esac
done
aws ssm get-command-invocation --command-id $CMD_ID --instance-id $MGMT_ID \
  --query '[Status,StandardOutputContent]' --output text
echo "IMAGE_TAG=$IMAGE_TAG"
[ "$st" = Success ] || die "빌드 실패($st) — 위 출력 확인"
save IMAGE_TAG
