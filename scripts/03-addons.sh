#!/bin/bash
# D. AWS Load Balancer Controller — Ingress 를 만들면 ALB 를 생성해 주는 컨트롤러
set -euo pipefail
source "$(dirname "$0")/../env.sh"

curl -fsSL -o "$PC_HOME/infra/lbc-iam-policy.json" \
  "https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/${LBC_VERSION}/docs/install/iam_policy.json"
aws iam get-policy --policy-arn arn:aws:iam::${ACCOUNT_ID}:policy/pc-policy-lbc >/dev/null 2>&1 || \
aws iam create-policy --policy-name pc-policy-lbc \
  --policy-document "file://$PC_HOME/infra/lbc-iam-policy.json" --tags Key=Project,Value=petclinic >/dev/null

# IRSA: 이 ServiceAccount 를 쓰는 Pod 만 ALB 를 만들 권한을 갖는다
eksctl create iamserviceaccount --cluster $CLUSTER \
  --namespace kube-system --name aws-load-balancer-controller \
  --role-name pc-irsa-lbc \
  --attach-policy-arn arn:aws:iam::${ACCOUNT_ID}:policy/pc-policy-lbc \
  --override-existing-serviceaccounts --approve

helm repo add eks https://aws.github.io/eks-charts >/dev/null && helm repo update >/dev/null
helm search repo eks/aws-load-balancer-controller --versions | head -3   # 보고서에 기록
helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system --version $LBC_CHART_VERSION \
  --set clusterName=$CLUSTER --set region=$AWS_REGION --set vpcId=$VPC_ID \
  --set serviceAccount.create=false --set serviceAccount.name=aws-load-balancer-controller

kubectl -n kube-system rollout status deploy/aws-load-balancer-controller
kubectl get ingressclass      # alb
kubectl top nodes             # metrics-server 동작 확인 (1~2분 뒤 값이 나오면 정상)
