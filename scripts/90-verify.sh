#!/bin/bash
# 4일차 검증 도우미 (기획서 4장) — 로컬에서 실행. 결과는 logs/verify-<날짜>/ 에 남는다
# 사용:
#   bash scripts/90-verify.sh loop <이름>        # V2·V6·V7: 0.5초마다 ALB 요청(was·DB 경유 페이지). Ctrl-C 로 끝내면 요약
#   bash scripts/90-verify.sh load <초> <VU>     # V3·V4: 클러스터 안 k6 Job 으로 ALB 에 부하 (네임스페이스 pc-load)
#   bash scripts/90-verify.sh unload             # 부하 Job·네임스페이스 삭제
#   bash scripts/90-verify.sh conns              # V4: pc_app 연결 수를 Pod IP 별로 (관리 EC2 → RDS, SSM)
#   bash scripts/90-verify.sh netpol             # V5: 허용·차단 경로 5가지를 임시 Pod 로 시험
set -euo pipefail
source "$(dirname "$0")/../env.sh"
cd "$PC_HOME"
OUT="$PC_HOME/logs/verify-$(date +%Y%m%d)"; mkdir -p "$OUT"
K6_IMAGE=grafana/k6:1.0.0
BUSYBOX=busybox:1.37

alb_dns() {
  aws elbv2 describe-load-balancers \
    --query "LoadBalancers[?starts_with(LoadBalancerName,'k8s-petclini-petclini')].DNSName | [0]" --output text
}

case ${1:-} in
loop)
  name=${2:?이름 필요 (예: v2)}
  require_aws 5
  URL="http://$(alb_dns)/owners?lastName="   # 목록 페이지 = web → was → DB 를 모두 지난다
  F="$OUT/$name-$(date +%H%M%S).tsv"
  summary() {
    echo
    awk -F'\t' '{n++; if ($2!="200") {bad++; if (!f) f=$1; l=$1}} END {
      printf "요청 %d · 200 아님 %d", n, bad; if (bad) printf " (처음 %s ·마지막 %s)", f, l; print ""}' "$F"
    echo "200 아닌 코드별:"; awk -F'\t' '$2!="200"{print $2}' "$F" | sort | uniq -c
    echo "기록: $F"; exit 0
  }
  trap summary INT
  log "$URL — Ctrl-C 로 종료"
  while :; do
    r=$(curl -s -o /dev/null -m 5 -w '%{http_code}\t%{time_total}' "$URL" || true)
    [ -n "$r" ] || r=$'000\t5'
    printf '%s\t%s\n' "$(date +%H:%M:%S.%3N)" "$r" | tee -a "$F" | awk -F'\t' '$2!="200"'   # 실패만 화면에
    sleep 0.5
  done ;;

load)
  secs=${2:-300}; vus=${3:-50}
  require_aws 5
  BASE="http://$(alb_dns)"
  tunnel_up
  kubectl create ns pc-load --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl -n pc-load create configmap k6 --dry-run=client -o yaml --from-literal=s.js="
import http from 'k6/http';
export const options = { vus: $vus, duration: '${secs}s' };
export default function () {
  http.get('$BASE/owners?lastName=');
  http.get('$BASE/vets');   // /vets.html 은 404 (1차 부하 때 요청 1/3 이 404 — 스크립트 오류)
  http.get('$BASE/owners/' + (1 + Math.floor(Math.random() * 10)));
}" | kubectl apply -f - >/dev/null
  kubectl -n pc-load delete job k6 --ignore-not-found >/dev/null
  kubectl -n pc-load apply -f - <<EOF >/dev/null
apiVersion: batch/v1
kind: Job
metadata: {name: k6}
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: k6
          image: $K6_IMAGE
          args: [run, --quiet, /s/s.js]
          resources: {requests: {cpu: 500m, memory: 256Mi}}
          volumeMounts: [{name: s, mountPath: /s}]
      volumes: [{name: s, configMap: {name: k6}}]
EOF
  log "부하 시작: ${secs}초 · VU $vus → $BASE  (시작 시각 기록: $(date +%H:%M:%S))"
  log "관찰: kubectl get hpa -n $NS -w   /  결과: kubectl logs -n pc-load job/k6" ;;

unload)
  require_aws 5; tunnel_up
  kubectl delete ns pc-load --ignore-not-found --wait=true ;;

conns)
  require_aws 5
  read -r HOST MASTER_ARN < <(aws rds describe-db-instances --db-instance-identifier $RDS_ID \
    --query 'DBInstances[0].[Endpoint.Address,MasterUserSecret.SecretArn]' --output text)
  PARAMS=.ssm-params.json; trap 'rm -f "$PARAMS"' EXIT
  { printf 'export HOST=%q MASTER_ARN=%q\n' "$HOST" "$MASTER_ARN"; tr -d '\r' < scripts/remote/processlist.sh; } \
    | jq -a -Rs '{commands: [.]}' > "$PARAMS"
  CMD_ID=$(aws ssm send-command --instance-ids $MGMT_ID --document-name AWS-RunShellScript \
    --comment "pc V4 processlist" --parameters file://$PARAMS --query Command.CommandId --output text)
  aws ssm wait command-executed --command-id $CMD_ID --instance-id $MGMT_ID || true
  aws ssm get-command-invocation --command-id $CMD_ID --instance-id $MGMT_ID \
    --query '[Status,StandardOutputContent,StandardErrorContent]' --output text | tee -a "$OUT/v4-conns.txt"
  echo "--- was Pod IP (위 pod_ip 와 맞춰 보기)"
  tunnel_up; kubectl get pod -n $NS -l tier=was -o wide | tee -a "$OUT/v4-conns.txt" ;;

netpol)
  require_aws 5; tunnel_up
  F="$OUT/v5-netpol-$(date +%H%M%S).txt"
  # 임시 Pod 는 tier 라벨만 같고 app.kubernetes.io/name 이 달라 Service·HPA·PDB 에 끼지 않는다
  # 새 Pod 는 정책이 붙기 전 잠깐 허용 상태일 수 있다(VPC CNI 표준 모드) → 5초 뒤 시험
  probe() {  # 기대(OPEN|BLOCKED) 설명 tier 대상 포트
    local want=$1 what=$2 tier=$3 host=$4 port=$5 got
    if kubectl run "v5-$RANDOM" -n $NS --image=$BUSYBOX --restart=Never --rm -i --quiet \
         --labels="app.kubernetes.io/name=v5-probe${tier:+,tier=$tier}" \
         -- sh -c "sleep 5; nc -z -w 3 $host $port" >/dev/null 2>&1; then got=OPEN; else got=BLOCKED; fi
    printf '%-8s 기대 %-7s 결과 %-7s %s\n' "$([ $got = $want ] && echo PASS || echo FAIL)" "$want" "$got" "$what" | tee -a "$F"
  }
  echo "# $(date '+%F %T %Z') V5 NetworkPolicy" | tee "$F"
  probe BLOCKED "web → DB 3306 (web 은 DB 에 직접 못 감)"      web db 3306
  probe OPEN    "web → was 8080 (허용 경로, 대조군)"           web was 8080
  probe OPEN    "was → DB 3306 (허용 경로, 대조군)"            was db 3306
  probe BLOCKED "라벨 없는 Pod → was 8080 (출처 제한)"          ""  was 8080
  probe BLOCKED "was → 인터넷 1.1.1.1:443 (외부 송신 차단)"     was 1.1.1.1 443
  echo "기록: $F" ;;

*) sed -n 2,9p "$0"; exit 1 ;;
esac
