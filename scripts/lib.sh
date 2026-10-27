# 공통 함수 — env.sh 가 source 한다. 직접 실행하지 않는다.

# Windows(Git Bash)의 aws·kubectl·jq 는 줄 끝에 \r 을 붙인다 → [ "$n" = 0 ] 같은 비교가 조용히 깨진다
# 그래서 Windows 에서만 \r 을 지우는 래퍼를 둔다 (관리 EC2·리눅스에서는 원래 명령 그대로)
if [[ ${OSTYPE:-} == msys* || ${OSTYPE:-} == cygwin* ]]; then
  aws()     { command aws "$@" | tr -d '\r'; }
  kubectl() { command kubectl "$@" | tr -d '\r'; }
  jq()      { command jq "$@" | tr -d '\r'; }
fi

log() { echo "[$(date +%H:%M:%S)] $*"; }
die() { echo "[$(date +%H:%M:%S)] 중단: $*" >&2; exit 1; }

# 값 하나를 .state.env 에 기록 (같은 이름이 있으면 교체)
save() {
  local name=$1 val=${!1}
  sed -i "/^export $name=/d" "$STATE_FILE"
  echo "export $name=$val" >> "$STATE_FILE"
  log "saved $name=$val"
}

# 자격 증명 확인 — 긴 작업 전에 반드시 호출
# 사용: require_aws [남아 있어야 할 분, 기본 30]
# 임시 자격 증명이면 만료까지 남은 시간을 보고, 모자라면 시작하지 않는다 (EKS 생성 도중 끊김 방지)
require_aws() {
  local need_min=${1:-30}
  ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null) \
    || die "AWS 자격 증명 무효. 'aws configure list'로 읽히는 위치 확인 후 재설정"
  export ACCOUNT_ID
  [ "$PC_OWNER" != "<OWNER>" ] || die "태그용 PC_OWNER 미설정: export PC_OWNER=<이름>"

  local exp
  exp=$(aws configure export-credentials --format env-no-export 2>/dev/null \
        | sed -n 's/^AWS_CREDENTIAL_EXPIRATION=//p')
  if [ -n "$exp" ]; then
    local left=$(( ($(date -d "$exp" +%s) - $(date +%s)) / 60 ))
    [ "$left" -ge "$need_min" ] || die "자격 증명 만료까지 ${left}분 — 이 작업은 ${need_min}분 이상 필요. 갱신 후 다시 실행"
    log "자격 증명 확인 (만료까지 ${left}분)"
  else
    log "자격 증명 확인 (장기 키 또는 만료 정보 없음)"
  fi
}

# --tag-specifications 값
# 사용: tagspec <ResourceType> <Name> [',{Key=..,Value=..}' 추가 태그]
tagspec() {
  echo "ResourceType=$1,Tags=[{Key=Name,Value=$2},{Key=Project,Value=$TAG_PROJECT},{Key=Owner,Value=$PC_OWNER},{Key=Env,Value=$TAG_ENV}${3:-}]"
}
# --tags 값 (RDS·IAM 등 Key=,Value= 목록을 받는 API)
tags_kv() {
  echo "Key=Project,Value=$TAG_PROJECT Key=Owner,Value=$PC_OWNER Key=Env,Value=$TAG_ENV"
}

# Name 태그로 EC2 계열 리소스 ID 조회 (없으면 빈 문자열)
# 사용: ec2_id <vpc|subnet|igw|rtb|sg|eip|nat|instance> <Name>
ec2_id() {
  local f="Name=tag:Name,Values=$2" out
  case $1 in
    vpc)      out=$(aws ec2 describe-vpcs --filters "$f" --query 'Vpcs[0].VpcId' --output text) ;;
    subnet)   out=$(aws ec2 describe-subnets --filters "$f" --query 'Subnets[0].SubnetId' --output text) ;;
    igw)      out=$(aws ec2 describe-internet-gateways --filters "$f" --query 'InternetGateways[0].InternetGatewayId' --output text) ;;
    rtb)      out=$(aws ec2 describe-route-tables --filters "$f" --query 'RouteTables[0].RouteTableId' --output text) ;;
    sg)       out=$(aws ec2 describe-security-groups --filters "$f" --query 'SecurityGroups[0].GroupId' --output text) ;;
    eip)      out=$(aws ec2 describe-addresses --filters "$f" --query 'Addresses[0].AllocationId' --output text) ;;
    nat)      out=$(aws ec2 describe-nat-gateways --filter "$f" Name=state,Values=pending,available \
                      --query 'NatGateways[0].NatGatewayId' --output text) ;;
    instance) out=$(aws ec2 describe-instances --filters "$f" Name=instance-state-name,Values=pending,running,stopping,stopped \
                      --query 'Reservations[0].Instances[0].InstanceId' --output text) ;;
    *) die "ec2_id: 모르는 종류 $1" ;;
  esac
  [ "$out" = "None" ] && out=""
  echo "$out"
}

# SG 인바운드 허용 — 이미 있으면 건너뜀
# 사용: allow_sg <대상 SG> <포트> <출처 SG> <설명>
allow_sg() {
  local err
  if err=$(aws ec2 authorize-security-group-ingress --group-id "$1" \
        --ip-permissions "IpProtocol=tcp,FromPort=$2,ToPort=$2,UserIdGroupPairs=[{GroupId=$3,Description=\"$4\"}]" 2>&1 >/dev/null); then
    log "SG $1 ← $3 :$2 허용"
  elif echo "$err" | grep -q 'InvalidPermission.Duplicate'; then
    log "SG $1 ← $3 :$2 이미 있음"
  else
    die "$err"
  fi
}

# 터널 — 로컬에서 kubectl 이 localhost:8443 → EKS 프라이빗 엔드포인트로 가도록 SSM 포트 포워딩을 백그라운드로 연다
# 관리 EC2 안에서 실행할 때는 PC_KUBE_DIRECT=1 로 건너뛴다
# SSM 세션은 20분(기본) 동안 데이터가 없으면 끊긴다 → 긴 대기 뒤 kubectl 을 쓰기 전에 다시 호출한다 (열려 있으면 그대로)
TUNNEL_PID=""
tunnel_up() {
  [ "${PC_KUBE_DIRECT:-0}" = 1 ] && return 0
  (echo > /dev/tcp/127.0.0.1/8443) 2>/dev/null && return 0
  tunnel_down   # 끊긴 이전 세션 프로세스 정리
  command -v session-manager-plugin >/dev/null || die "Session Manager 플러그인 없음 (설치 필요)"
  local ep host
  ep=$(aws eks describe-cluster --name "$CLUSTER" --query cluster.endpoint --output text)
  host=${ep#https://}
  # 래퍼(파이프)를 거치면 $! 가 tr 을 가리켜 터널을 못 닫는다 → 원래 명령으로 실행
  command aws ssm start-session --target "$MGMT_ID" \
    --document-name AWS-StartPortForwardingSessionToRemoteHost \
    --parameters "host=$host,portNumber=443,localPortNumber=8443" >/dev/null 2>&1 &
  TUNNEL_PID=$!
  trap tunnel_down EXIT
  for _ in $(seq 1 30); do
    (echo > /dev/tcp/127.0.0.1/8443) 2>/dev/null && { log "터널 열림 (pid $TUNNEL_PID)"; return 0; }
    sleep 2
  done
  die "터널이 60초 안에 열리지 않음"
}
tunnel_down() { [ -n "$TUNNEL_PID" ] && kill "$TUNNEL_PID" 2>/dev/null; TUNNEL_PID=""; }

# 노드 그룹 ASG 의 실행 중 인스턴스 수 (kubectl 없이 노드 수 확인)
asg_instances() {
  local asg
  asg=$(aws eks describe-nodegroup --cluster-name "$CLUSTER" --nodegroup-name "$NODEGROUP" \
        --query 'nodegroup.resources.autoScalingGroups[0].name' --output text)
  aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$asg" \
    --query 'length(AutoScalingGroups[0].Instances)' --output text
}
