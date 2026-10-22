#!/bin/bash
# 프로젝트 종료 — 전부 삭제 (순서 중요)
# Ingress 를 클러스터보다 먼저 지워야 LBC 가 ALB · SG 를 정리한다.
# 클러스터를 먼저 지우면 ALB 가 고아로 남고 그 ENI 때문에 VPC 삭제가 실패한다.
source "$(dirname "$0")/../env.sh"
read -p "pc-* 리소스를 모두 삭제합니다. 계속하려면 yes 입력: " ANS; [ "$ANS" = yes ] || exit 1

# 1) Ingress → ALB
kubectl delete ingress pc-ingress -n petclinic --wait=true 2>/dev/null || true
echo "ALB 삭제 대기..."
while aws elbv2 describe-load-balancers --names pc-alb >/dev/null 2>&1; do sleep 10; done

# 2) 앱
kubectl delete ns petclinic --wait=true 2>/dev/null || true

# 3) RDS (스냅샷 없이 삭제 — 관리 비밀도 함께 삭제됨)
aws rds delete-db-instance --db-instance-identifier pc-rds --skip-final-snapshot >/dev/null 2>&1 || true

# 4) 클러스터 (IRSA 스택 포함)
eksctl delete iamserviceaccount --cluster $CLUSTER --namespace kube-system --name aws-load-balancer-controller --wait || true
eksctl delete cluster -f "$PC_HOME/infra/cluster.yaml" --wait

# 5) RDS 정리
aws rds wait db-instance-deleted --db-instance-identifier pc-rds 2>/dev/null || true
aws rds delete-db-subnet-group --db-subnet-group-name pc-dbsubnet || true
aws ec2 delete-security-group --group-id $SG_RDS || true

# 6) ECR · IAM
for R in pc-web pc-was; do aws ecr delete-repository --repository-name $R --force >/dev/null || true; done
aws iam delete-policy --policy-arn arn:aws:iam::${ACCOUNT_ID}:policy/pc-policy-lbc || true

# 7) VPC — NAT → EIP → 남은 SG(LBC 가 만든 k8s-*) → 서브넷 → 라우팅 → IGW → VPC
aws ec2 delete-nat-gateway --nat-gateway-id $NAT_ID >/dev/null || true
aws ec2 wait nat-gateway-deleted --nat-gateway-ids $NAT_ID || true
aws ec2 release-address --allocation-id $EIP_NAT || true
for SG in $(aws ec2 describe-security-groups --filters Name=vpc-id,Values=$VPC_ID \
    --query 'SecurityGroups[?GroupName!=`default`].GroupId' --output text); do
  aws ec2 delete-security-group --group-id $SG || true
done
for S in $SUBNET_PUB_A $SUBNET_PUB_C $SUBNET_APP_A $SUBNET_APP_C $SUBNET_DB_A $SUBNET_DB_C; do
  aws ec2 delete-subnet --subnet-id $S || true
done
for R in $RTB_PUB $RTB_APP $RTB_DB; do aws ec2 delete-route-table --route-table-id $R || true; done
aws ec2 detach-internet-gateway --internet-gateway-id $IGW_ID --vpc-id $VPC_ID || true
aws ec2 delete-internet-gateway --internet-gateway-id $IGW_ID || true
aws ec2 delete-vpc --vpc-id $VPC_ID

# 8) 최종 확인 — 결과가 비어 있어야 함 (삭제 직후엔 몇 분간 남아 보일 수 있음)
aws resourcegroupstaggingapi get-resources --tag-filters Key=Project,Values=petclinic \
  --query 'ResourceTagMappingList[].ResourceARN'
