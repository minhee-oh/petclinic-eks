#!/bin/bash
# C. EKS 클러스터 + 관리형 노드그룹 (약 15~25분)
set -euo pipefail
source "$(dirname "$0")/../env.sh"

envsubst < "$PC_HOME/infra/cluster.yaml.tpl" > "$PC_HOME/infra/cluster.yaml"
if grep -n '\${' "$PC_HOME/infra/cluster.yaml"; then echo "치환 안 된 변수가 있음 — 01-vpc.sh 를 먼저 실행"; exit 1; fi

eksctl create cluster -f "$PC_HOME/infra/cluster.yaml"

CLUSTER_SG=$(aws eks describe-cluster --name $CLUSTER \
  --query cluster.resourcesVpcConfig.clusterSecurityGroupId --output text); save CLUSTER_SG

kubectl get nodes -L pc/role,topology.kubernetes.io/zone,node.kubernetes.io/instance-type
kubectl get pods -A
