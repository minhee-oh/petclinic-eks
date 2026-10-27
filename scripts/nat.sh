#!/bin/bash
# NAT 2개를 지우고(EIP는 보관) 다시 만드는 스크립트 — 작업하지 않는 날 NAT 시간 요금을 멈추기 위함
# 사용: bash scripts/nat.sh status | down | up
#   down : VPC 안에 켜진 EC2(노드·관리 EC2)가 없을 때만 NAT 삭제. EIP 는 해제하지 않는다 → 다시 만들면 나가는 IP 가 같다
#   up   : 같은 EIP 로 NAT 재생성 → available 대기 → app·mgmt 라우트 테이블 4개의 0.0.0.0/0 을 새 NAT 로 교체. start.sh 보다 먼저 실행
# 이름 태그로 찾으므로 다시 실행해도 안전하다 (있으면 건너뜀)
set -euo pipefail
source "$(dirname "$0")/../env.sh"
require_aws 15

VPC_ID=$(ec2_id vpc pc-vpc); [ -n "$VPC_ID" ] || die "pc-vpc 없음"

nat_of() {  # AZ접미사 → 살아 있는 NAT ID (없으면 빈 문자열)
  ec2_id nat pc-nat-$1
}

show() {
  log "NAT (VPC 안, 삭제되지 않은 것)"
  aws ec2 describe-nat-gateways --filter Name=vpc-id,Values=$VPC_ID Name=state,Values=pending,available,deleting \
    --query 'NatGateways[].[Tags[?Key==`Name`]|[0].Value,NatGatewayId,State,NatGatewayAddresses[0].AllocationId]' --output table
  log "EIP (보관 중이어야 함)"
  aws ec2 describe-addresses --filters Name=tag:Project,Values=$TAG_PROJECT \
    --query 'Addresses[].[Tags[?Key==`Name`]|[0].Value,AllocationId,AssociationId]' --output table
  log "기본 경로 (app·mgmt)"
  local r
  for r in pc-rtb-app-a pc-rtb-mgmt-a pc-rtb-app-c pc-rtb-mgmt-c; do
    printf '%-14s %s\n' "$r" "$(aws ec2 describe-route-tables --filters Name=tag:Name,Values=$r \
      --query "RouteTables[0].Routes[?DestinationCidrBlock=='0.0.0.0/0'].[NatGatewayId,State]" --output text)"
  done
}

down() {
  local running
  running=$(aws ec2 describe-instances --filters Name=vpc-id,Values=$VPC_ID Name=instance-state-name,Values=pending,running \
    --query 'Reservations[].Instances[].InstanceId' --output text)
  [ -z "$running" ] || die "켜진 EC2 가 있음($running) — 노드·관리 EC2 는 NAT 로 밖에 나간다. 먼저 stop.sh"

  local z ids=""
  for z in a c; do
    local id; id=$(nat_of $z)
    if [ -n "$id" ]; then ids="$ids $id"; log "삭제 대상 pc-nat-$z = $id"; else log "pc-nat-$z 없음 — 건너뜀"; fi
  done
  [ -n "$ids" ] || { log "지울 NAT 없음"; show; return; }

  read -r -p "NAT$ids 를 삭제합니다(EIP 는 보관). 계속하려면 yes 입력: " ANS
  [ "$ANS" = yes ] || die "취소"
  for id in $ids; do aws ec2 delete-nat-gateway --nat-gateway-id $id >/dev/null; done

  log "삭제 완료 대기 (보통 1~5분)"
  local i st
  for i in $(seq 1 60); do
    st=$(aws ec2 describe-nat-gateways --nat-gateway-ids $ids --query 'NatGateways[].State' --output text)
    [ -z "$(echo "$st" | tr '\t' '\n' | grep -v '^deleted$' || true)" ] && break
    sleep 10
  done
  [ "$i" -lt 60 ] || die "10분 안에 deleted 가 되지 않음 — 콘솔에서 확인"
  log "NAT 삭제 완료. 라우트는 blackhole 상태로 남는 것이 정상(up 이 교체)"
  show
}

up() {
  local z eip sub nat
  for z in a c; do
    eip=$(ec2_id eip pc-eip-nat-$z);        [ -n "$eip" ] || die "pc-eip-nat-$z 없음 — EIP 를 해제했다면 10-network.sh 로 새로 만든다(나가는 IP 가 바뀜)"
    sub=$(ec2_id subnet pc-subnet-pub-$z);  [ -n "$sub" ] || die "pc-subnet-pub-$z 없음"
    nat=$(nat_of $z)
    if [ -z "$nat" ]; then
      nat=$(aws ec2 create-nat-gateway --subnet-id $sub --allocation-id $eip \
        --tag-specifications "$(tagspec natgateway pc-nat-$z)" --query NatGateway.NatGatewayId --output text)
      log "pc-nat-$z 생성 요청 = $nat"
    else
      log "pc-nat-$z 이미 있음 = $nat"
    fi
    if [ $z = a ]; then NAT_A=$nat; save NAT_A; else NAT_C=$nat; save NAT_C; fi
  done

  log "NAT available 대기 (1~3분)"
  aws ec2 wait nat-gateway-available --nat-gateway-ids $NAT_A $NAT_C

  local r t rtb
  for r in app-a:$NAT_A mgmt-a:$NAT_A app-c:$NAT_C mgmt-c:$NAT_C; do
    t=${r#*:}; rtb=$(ec2_id rtb pc-rtb-${r%%:*}); [ -n "$rtb" ] || die "pc-rtb-${r%%:*} 없음"
    aws ec2 replace-route --route-table-id $rtb --destination-cidr-block 0.0.0.0/0 --nat-gateway-id $t 2>/dev/null \
      || aws ec2 create-route --route-table-id $rtb --destination-cidr-block 0.0.0.0/0 --nat-gateway-id $t >/dev/null
  done

  show
  local bad
  bad=$(for r in pc-rtb-app-a pc-rtb-mgmt-a pc-rtb-app-c pc-rtb-mgmt-c; do
          aws ec2 describe-route-tables --filters Name=tag:Name,Values=$r \
            --query "RouteTables[0].Routes[?DestinationCidrBlock=='0.0.0.0/0'].State" --output text; done | grep -v '^active$' || true)
  [ -z "$bad" ] || die "active 가 아닌 기본 경로가 있음 — 위 표 확인"
  log "기본 경로 4개 active. 이제 start.sh"
}

case ${1:-} in
  status) show ;;
  down)   down ;;
  up)     up ;;
  *) echo "사용: bash scripts/nat.sh status|down|up"; exit 1 ;;
esac
