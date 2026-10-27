#!/bin/bash
# 증빙 덤프 (보고서 6.4 E2) — 로컬에서 실행. 읽기만 한다(변경 없음)
#   결과: evidence/<시각>/NN-이름.txt (파일마다 첫 줄에 명령·시각)
#   마스킹: 계정 ID 를 ************ 로 바꿔 저장 → 마지막에 마스킹 검사(계정 ID·액세스 키·비밀 값 흔적) 0건이어야 통과
#   K8s Secret 은 덤프 대상에서 뺀다(-o yaml 은 Deployment·HPA·PDB 만)
# 사용: bash scripts/80-evidence.sh            # 3-9(3일차 스냅샷), 4-6(최종)
set -euo pipefail
source "$(dirname "$0")/../env.sh"
require_aws 15
tunnel_up

OUT="$PC_HOME/evidence/$(date +%Y%m%d-%H%M)"
mkdir -p "$OUT"
N=0

# 명령 하나를 실행해 마스킹 후 파일로 — 실패해도 다음 항목은 계속(파일에 오류를 남김)
dump() {  # 이름 명령...
  local name=$1; shift
  N=$((N + 1))
  local f; f=$(printf '%s/%02d-%s.txt' "$OUT" "$N" "$name")
  { echo "# $(date '+%F %T %Z') \$ $*"; "$@" 2>&1 || echo "# (종료 코드 $?)"; } \
    | sed "s/$ACCOUNT_ID/************/g" > "$f"
  log "$(basename "$f")"
}

# ── 쿠버네티스 ─────────────────────────────────────
dump k8s-all   kubectl get all,hpa,pdb,networkpolicy,gateway,httproute,targetgroupbinding -A -o wide
dump k8s-nodes kubectl get nodes -o wide -L topology.kubernetes.io/zone
dump k8s-app-yaml kubectl get deploy,hpa,pdb -n $NS -o yaml
dump k8s-externalsecret kubectl get secretstore,externalsecret -n $NS
dump k8s-ns-labels kubectl get ns $NS --show-labels

# ── EKS ───────────────────────────────────────────
dump eks-vpc-config aws eks describe-cluster --name $CLUSTER --query 'cluster.{version:version,vpc:resourcesVpcConfig,logging:logging}'
dump eks-addon-vpc-cni aws eks describe-addon --cluster-name $CLUSTER --addon-name vpc-cni --query 'addon.{version:addonVersion,status:status,config:configurationValues}'
dump eks-addons aws eks list-addons --cluster-name $CLUSTER
dump eks-pod-identity aws eks list-pod-identity-associations --cluster-name $CLUSTER
dump eks-nodegroup aws eks describe-nodegroup --cluster-name $CLUSTER --nodegroup-name $NODEGROUP \
  --query 'nodegroup.{status:status,scaling:scalingConfig,instanceTypes:instanceTypes,subnets:subnets,health:health}'

# ── RDS ───────────────────────────────────────────
dump rds-instance aws rds describe-db-instances --db-instance-identifier $RDS_ID \
  --query 'DBInstances[0].{class:DBInstanceClass,engine:EngineVersion,status:DBInstanceStatus,multiAZ:MultiAZ,az:AvailabilityZone,secondaryAZ:SecondaryAvailabilityZone,encrypted:StorageEncrypted,deletionProtection:DeletionProtection,public:PubliclyAccessible,backupDays:BackupRetentionPeriod,paramGroup:DBParameterGroups[0].DBParameterGroupName,logs:EnabledCloudwatchLogsExports}'
dump rds-params aws rds describe-db-parameters --db-parameter-group-name pc-mysql84 --source user \
  --query 'Parameters[].[ParameterName,ParameterValue]' --output table
dump rds-proxy aws rds describe-db-proxies --query 'DBProxies[].{name:DBProxyName,status:Status,requireTLS:RequireTLS,endpoint:Endpoint}'

# ── ALB · 대상 그룹 ───────────────────────────────
TGS=$(kubectl get targetgroupbindings -n $NS -o jsonpath='{.items[*].spec.targetGroupARN}' 2>/dev/null || true)
ALB_ARN=""
for tg in $TGS; do
  short=${tg#*:targetgroup/}; short=${short%%/*}   # arn:...:targetgroup/<이름>/<id> → <이름> (파일 이름에 ARN·계정 ID 를 넣지 않게)
  dump "tg-health-$short" aws elbv2 describe-target-health --target-group-arn "$tg"
  dump "tg-attrs-$short"  aws elbv2 describe-target-group-attributes --target-group-arn "$tg"
  [ -n "$ALB_ARN" ] || ALB_ARN=$(aws elbv2 describe-target-groups --target-group-arns "$tg" \
                                   --query 'TargetGroups[0].LoadBalancerArns[0]' --output text)
done
if [ -n "$ALB_ARN" ] && [ "$ALB_ARN" != None ]; then
  dump alb aws elbv2 describe-load-balancers --load-balancer-arns "$ALB_ARN" \
    --query 'LoadBalancers[0].{name:LoadBalancerName,dns:DNSName,scheme:Scheme,azs:AvailabilityZones[].ZoneName}'
  dump alb-listeners aws elbv2 describe-listeners --load-balancer-arn "$ALB_ARN"
  dump alb-capacity-reservation aws elbv2 describe-capacity-reservation --load-balancer-arn "$ALB_ARN"
fi

# ── ECR ───────────────────────────────────────────
dump ecr-repos aws ecr describe-repositories --repository-names pc-web pc-was \
  --query 'repositories[].{name:repositoryName,mutability:imageTagMutability,encryption:encryptionConfiguration.encryptionType}'
dump ecr-images-web aws ecr describe-images --repository-name pc-web --query 'imageDetails[].{tags:imageTags,digest:imageDigest,pushed:imagePushedAt}'
dump ecr-images-was aws ecr describe-images --repository-name pc-was --query 'imageDetails[].{tags:imageTags,digest:imageDigest,pushed:imagePushedAt}'
dump ecr-scanning aws ecr get-registry-scanning-configuration

# ── 네트워크 ──────────────────────────────────────
dump vpc-route-tables aws ec2 describe-route-tables --filters Name=vpc-id,Values=$VPC_ID \
  --query 'RouteTables[].{name:Tags[?Key==`Name`]|[0].Value,subnets:Associations[].SubnetId,routes:Routes[].[DestinationCidrBlock||DestinationPrefixListId,GatewayId||NatGatewayId]}'
dump vpc-sg-rules aws ec2 describe-security-group-rules \
  --filters Name=group-id,Values=$SG_NODE,$SG_MGMT,$SG_RDS,$CLUSTER_SG \
  --query 'SecurityGroupRules[].[GroupId,IsEgress,IpProtocol,FromPort,ToPort,CidrIpv4||ReferencedGroupInfo.GroupId,Description]' --output table
dump vpc-subnets aws ec2 describe-subnets --filters Name=vpc-id,Values=$VPC_ID \
  --query 'Subnets[].[Tags[?Key==`Name`]|[0].Value,CidrBlock,AvailabilityZone,MapPublicIpOnLaunch]' --output table

# ── 마스킹 검사 — 하나라도 걸리면 실패(그 파일은 보고서에 쓰지 않는다) ──
# 계정 ID 원문 · 액세스 키 ID · 비밀 값을 담는 필드 · Secret 객체
#   "password" 는 값이 붙은 경우만 — secretKeyRef 의 "key":"password"(키 이름 참조)는 비밀이 아니다 (3-9 첫 실행 오탐)
PAT="$ACCOUNT_ID|AKIA[0-9A-Z]{16}|ASIA[0-9A-Z]{16}|SecretString|\"password\" *: *\"|kind: Secret$"
hits=$( { grep -rEn "$PAT" "$OUT"; ls "$OUT" | grep -n "$ACCOUNT_ID"; } || true)   # 파일 이름도 검사
if [ -n "$hits" ]; then
  echo "$hits" | sed "s/$ACCOUNT_ID/<ACCOUNT_ID>/g" | cut -c1-200
  die "마스킹 검사 실패: $(echo "$hits" | wc -l)건 — 위 파일 확인"
fi
log "마스킹 검사 0건 — $OUT ($N개 파일)"
