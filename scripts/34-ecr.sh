#!/bin/bash
# 3-4 ECR 저장소 — 로컬에서 실행. 다시 실행해도 안전(있으면 설정만 다시 맞춤)
#   태그 변경 불가(IMMUTABLE): 같은 태그로 다른 이미지를 덮어쓸 수 없다 → 배포된 태그 = 검증한 이미지
#   향상된 스캔(Inspector, 지속 스캔): 푸시 뒤 새 CVE 가 나와도 감시. 푸시 "전" 차단은 Trivy(60-build-push.sh)가 맡는다
#   수명 주기: 태그 없는 이미지 1일, 최근 10개 유지(롤백 범위)
# 향상된 스캔은 레지스트리(계정) 단위 설정이라 pc-* 저장소만 규칙에 넣는다
set -euo pipefail
source "$(dirname "$0")/../env.sh"
require_aws 10
cd "$PC_HOME"

for R in pc-web pc-was; do
  if ! aws ecr describe-repositories --repository-names $R >/dev/null 2>&1; then
    aws ecr create-repository --repository-name $R \
      --image-tag-mutability IMMUTABLE \
      --encryption-configuration encryptionType=AES256 \
      --tags $(tags_kv) Key=Name,Value=$R >/dev/null
    log "ECR $R 생성"
  fi
  aws ecr put-lifecycle-policy --repository-name $R \
    --lifecycle-policy-text file://infra/ecr-lifecycle.json >/dev/null
done

if aws ecr put-registry-scanning-configuration --scan-type ENHANCED \
     --rules '[{"scanFrequency":"CONTINUOUS_SCAN","repositoryFilters":[{"filter":"pc-*","filterType":"WILDCARD"}]}]' >/dev/null; then
  log "향상된 스캔(ENHANCED, CONTINUOUS_SCAN, pc-*) 설정"
else
  log "향상된 스캔 설정 실패(권한·Inspector) — 기본 스캔으로 대체"
  for R in pc-web pc-was; do
    aws ecr put-image-scanning-configuration --repository-name $R \
      --image-scanning-configuration scanOnPush=true >/dev/null
  done
fi

aws ecr describe-repositories --repository-names pc-web pc-was \
  --query 'repositories[].[repositoryName,imageTagMutability,encryptionConfiguration.encryptionType,repositoryUri]' --output table
aws ecr get-registry-scanning-configuration --query 'scanningConfiguration.[scanType,rules[0].scanFrequency,rules[0].repositoryFilters[0].filter]' --output text
