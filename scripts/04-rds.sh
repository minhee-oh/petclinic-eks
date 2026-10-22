#!/bin/bash
# E. RDS MySQL 8.4 — DB 서브넷(인터넷 경로 없음)에, 클러스터 SG 에서만 3306 허용
# 비밀번호는 RDS 가 만들어 Secrets Manager 에 보관 (--manage-master-user-password)
set -euo pipefail
source "$(dirname "$0")/../env.sh"

MULTI_AZ=${MULTI_AZ:---no-multi-az}   # Multi-AZ 로 하려면: MULTI_AZ=--multi-az ./scripts/04-rds.sh

SG_RDS=$(aws ec2 create-security-group --group-name pc-sg-rds \
  --description "petclinic rds - from eks cluster sg only" --vpc-id $VPC_ID \
  --tag-specifications 'ResourceType=security-group,Tags=[{Key=Name,Value=pc-sg-rds},{Key=Project,Value=petclinic}]' \
  --query GroupId --output text); save SG_RDS
aws ec2 authorize-security-group-ingress --group-id $SG_RDS \
  --protocol tcp --port 3306 --source-group $CLUSTER_SG >/dev/null

aws rds create-db-subnet-group --db-subnet-group-name pc-dbsubnet \
  --db-subnet-group-description "petclinic db subnets" \
  --subnet-ids $SUBNET_DB_A $SUBNET_DB_C --tags Key=Project,Value=petclinic >/dev/null

MYSQL_VER=$(aws rds describe-db-engine-versions --engine mysql --engine-version 8.4 --default-only \
  --query 'DBEngineVersions[0].EngineVersion' --output text); save MYSQL_VER

aws rds create-db-instance --db-instance-identifier pc-rds \
  --engine mysql --engine-version $MYSQL_VER --db-instance-class db.t3.small \
  $MULTI_AZ --storage-type gp3 --allocated-storage 20 --storage-encrypted \
  --db-name petclinic --master-username pcadmin --manage-master-user-password \
  --db-subnet-group-name pc-dbsubnet --vpc-security-group-ids $SG_RDS \
  --no-publicly-accessible --backup-retention-period 1 \
  --tags Key=Project,Value=petclinic >/dev/null

echo "RDS 생성 대기 (10~25분) — 기다리는 동안 다른 터미널에서 05-build-push.sh 를 진행해도 됨"
aws rds wait db-instance-available --db-instance-identifier pc-rds

DB_HOST=$(aws rds describe-db-instances --db-instance-identifier pc-rds \
  --query 'DBInstances[0].Endpoint.Address' --output text); save DB_HOST
DB_SECRET_ARN=$(aws rds describe-db-instances --db-instance-identifier pc-rds \
  --query 'DBInstances[0].MasterUserSecret.SecretArn' --output text); save DB_SECRET_ARN

# 클러스터 안에서 접속 확인
DB_PASS=$(aws secretsmanager get-secret-value --secret-id "$DB_SECRET_ARN" \
  --query SecretString --output text | jq -r .password)
kubectl run dbtest --rm -i --restart=Never --image=mysql:8.4 \
  --env=MYSQL_PWD="$DB_PASS" -- mysql -h $DB_HOST -u pcadmin -e "SELECT VERSION(); SHOW DATABASES;"
unset DB_PASS
