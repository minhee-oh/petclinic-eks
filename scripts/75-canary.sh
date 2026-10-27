#!/bin/bash
# 4-5 수직 묶음 카나리 — 로컬에서 실행 (터널은 tunnel_up 이 자동으로 엶). 매니페스트: k8s/45-canary.yaml
# 사용:
#   bash scripts/75-canary.sh up <카나리 태그>     # 카나리 web·was 1개씩 + 헤더 선공개(가중치 0) — 60-build-push 로 그 태그를 먼저 push
#   bash scripts/75-canary.sh weight <카나리 %>   # 가중치만 바꿈 (예: 10 → 50 → 100, 0 = 헤더만)
#   bash scripts/75-canary.sh measure [요청 수]   # 헤더 없이 N번(기본 200) + x-canary 헤더 20번 → 버전별 개수·5xx
#   bash scripts/75-canary.sh down                # 되돌리기: HTTPRoute 를 stable 100% 로(40-gateway.yaml) → 카나리 삭제
set -euo pipefail
source "$(dirname "$0")/../env.sh"
cd "$PC_HOME"
NS=petclinic
OUT="$PC_HOME/logs/verify-$(date +%Y%m%d)"; mkdir -p "$OUT"
ECR() { echo "$ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com"; }
# TGB 이름은 k8s-<ns>-<svc 앞부분>-<해시> 로 잘려서 'web-canary' 가 안 들어간다(10/26 실측) → serviceRef 로 찾는다
tgb_canary() { kubectl -n $NS get targetgroupbindings.elbv2.k8s.aws -o jsonpath='{.items[*].spec.serviceRef.name}' | tr ' ' '\n' | grep -qx web-canary; }

render() {  # 카나리% — CANARY_TAG(.state.env)로 매니페스트를 채워 apply
  local cw=$1
  : "${CANARY_TAG:?.state.env 에 CANARY_TAG 없음 — up 을 먼저}"
  sed -e "s#__WEB_IMAGE__#$(ECR)/pc-web:$CANARY_TAG#" -e "s#__WAS_IMAGE__#$(ECR)/pc-was:$CANARY_TAG#" \
      -e "s#__STABLE_W__#$((100 - cw))#" -e "s#__CANARY_W__#$cw#" k8s/45-canary.yaml | kubectl apply -f -
}

case ${1:-} in
up)
  CANARY_TAG=${2:?카나리 태그 필요 (60-build-push 로 push 한 태그)}
  require_aws 20; tunnel_up
  # stable 태그는 지금 돌고 있는 web 에서 읽어 IMAGE_TAG 로 되돌린다 (60-build-push 가 카나리 태그로 덮어썼으므로)
  IMAGE_TAG=$(kubectl -n $NS get deploy web -o jsonpath='{.spec.template.spec.containers[0].image}'); IMAGE_TAG=${IMAGE_TAG##*:}
  [ "$IMAGE_TAG" != "$CANARY_TAG" ] || die "stable 과 카나리 태그가 같음 ($IMAGE_TAG)"
  save IMAGE_TAG; save CANARY_TAG
  for r in pc-web pc-was; do
    aws ecr describe-images --repository-name $r --image-ids imageTag=$CANARY_TAG >/dev/null 2>&1 \
      || die "$r:$CANARY_TAG 이 ECR 에 없음 — IMAGE_TAG=$CANARY_TAG bash scripts/60-build-push.sh 먼저"
  done
  log "stable $IMAGE_TAG / 카나리 $CANARY_TAG"
  # readiness gate 는 Pod 생성 시점에 TGB 가 있어야 주입된다 → Service·TGC·HTTPRoute 먼저, TGB 확인 뒤 Deployment
  # (한 파일이라 Deployment 도 같이 만들어지므로, TGB 가 생긴 뒤 Pod 를 다시 만들어 게이트를 붙인다)
  render 0
  log "web-canary TargetGroupBinding 대기"
  for _ in $(seq 1 60); do
    tgb_canary && break
    sleep 5
  done
  tgb_canary || die "web-canary TGB 가 5분 안에 안 생김"
  kubectl -n $NS rollout restart deploy/web-canary
  kubectl -n $NS rollout status deploy/was-canary --timeout=5m
  kubectl -n $NS rollout status deploy/web-canary --timeout=5m
  kubectl -n $NS get pod -l track=canary -o wide
  log "카나리 준비 — 지금은 x-canary: true 헤더만 카나리로 간다. 다음: measure → weight 10" ;;

weight)
  cw=${2:?카나리 % 필요 (0~100)}
  [ "$cw" -ge 0 ] && [ "$cw" -le 100 ] || die "0~100"
  require_aws 5; tunnel_up
  render "$cw"
  kubectl -n $NS get httproute web -o jsonpath='{range .spec.rules[1].backendRefs[*]}{.name}={.weight}{"  "}{end}'; echo
  log "ALB 규칙 반영까지 10~30초 — 그 뒤 measure" ;;

measure)
  n=${2:-200}
  require_aws 5
  ADDR=$(aws elbv2 describe-load-balancers \
    --query "LoadBalancers[?starts_with(LoadBalancerName,'k8s-petclini-petclini')].DNSName | [0]" --output text)
  F="$OUT/canary-$(date +%H%M%S).tsv"
  hit() {  # 표시 헤더... — 응답 코드와 X-App-Version 을 한 줄로
    curl -s -o /dev/null -D - -m 5 "$@" "http://$ADDR/owners?lastName=" \
      | awk -v t="$label" 'tolower($1)=="x-app-version:"{v=$2} /^HTTP\//{c=$2} END{gsub("\r","",v); print t"\t"c"\t"v}'
  }
  echo "# $(date '+%F %T') 카나리 측정 — 헤더 없음 $n번, x-canary 20번" | tee "$F"
  label=plain;  for _ in $(seq 1 "$n"); do hit; done >> "$F"
  label=header; for _ in $(seq 1 20);   do hit -H 'x-canary: true'; done >> "$F"
  echo "구분  응답코드  버전  개수"
  awk -F'\t' 'NR>1{k=$1"  "$2"  "$3; c[k]++} END{for(k in c) print k"  "c[k]}' "$F" | sort
  echo "기록: $F" ;;

down)
  require_aws 5; tunnel_up
  kubectl apply -f k8s/40-gateway.yaml   # HTTPRoute web → stable 100% (카나리로 가던 요청을 먼저 끊는다)
  sleep 30                               # ALB 규칙 반영 + 진행 중 요청
  kubectl -n $NS delete deploy web-canary was-canary --ignore-not-found
  kubectl -n $NS delete svc web-canary was-canary --ignore-not-found
  kubectl -n $NS delete targetgroupconfiguration web-canary --ignore-not-found
  log "카나리 제거 — stable 100%" ;;

*) sed -n 2,7p "$0"; exit 1 ;;
esac
