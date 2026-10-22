# eksctl 설정 템플릿 — 30-cluster.sh 가 envsubst 로 infra/cluster.yaml 을 만든다 (결과 파일은 git 제외)
# 엔드포인트: eksctl 은 처음부터 프라이빗 전용으로 만들 수 없다(공식 문서) →
#   생성 중에만 퍼블릭을 작업자 IP /32 로 제한해 열고, 30-cluster.sh 가 생성 직후 프라이빗 전용으로 닫는다
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig
metadata:
  name: ${CLUSTER}
  region: ${AWS_REGION}
  version: "${K8S_VERSION}"
  tags:
    Project: ${TAG_PROJECT}
    Owner: ${PC_OWNER}
    Env: ${TAG_ENV}

# 인증은 액세스 엔트리(API) — aws-auth ConfigMap 을 쓰지 않는다
# 클러스터를 만든 로컬 IAM 주체는 자동으로 관리자(bootstrapClusterCreatorAdminPermissions 기본 true).
#   같은 주체를 accessEntries 에 또 넣으면 중복 엔트리가 된다 → 5일 동안은 자동 엔트리를 그대로 쓴다.
#   운영이라면: 이 값을 false 로 두고 운영자 역할을 명시 엔트리로 넣어 생성자 권한을 회수한다 (보고서 기재)
# 관리 EC2 역할은 따로 엔트리가 있어야 kubectl 가능(대체 경로·빌드 후 배포)
accessConfig:
  authenticationMode: API
  bootstrapClusterCreatorAdminPermissions: true
  accessEntries:
    - principalARN: arn:aws:iam::${ACCOUNT_ID}:role/pc-role-mgmt
      accessPolicies:
        - policyARN: arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy
          accessScope:
            type: cluster

vpc:
  id: ${VPC_ID}
  # 퍼블릭 서브넷은 eksctl 에 넘기지 않는다 — ALB 는 LBC 가 elb 태그로 찾고, 컨트롤 플레인 ENI 가 퍼블릭에 생길 여지를 없앤다
  subnets:
    private:
      app-a:  { id: ${SUBNET_APP_A} }
      app-c:  { id: ${SUBNET_APP_C} }
      mgmt-a: { id: ${SUBNET_MGMT_A} }
      mgmt-c: { id: ${SUBNET_MGMT_C} }
  # 컨트롤 플레인 ENI 는 mgmt 구역에만. create 에 반영되지 않으면 30-cluster.sh 가 update-cluster-config 로 옮긴다
  controlPlaneSubnetIDs: [${SUBNET_MGMT_A}, ${SUBNET_MGMT_C}]
  clusterEndpoints:
    privateAccess: true
    publicAccess: true            # 생성 중에만. 30-cluster.sh 가 false 로 닫는다
  publicAccessCIDRs: ["${MY_IP}/32"]

addons:
  - name: vpc-cni
    # 이 설정이 없으면 NetworkPolicy 객체를 받아도 아무것도 막지 않는다 (V5)
    configurationValues: '{"enableNetworkPolicy": "true"}'
  - name: coredns
  - name: kube-proxy
  - name: eks-pod-identity-agent

# Pod 단위 IAM 은 Pod Identity (IRSA·OIDC 공급자 없음). 서비스 계정은 각 Helm 차트가 만든다
iam:
  podIdentityAssociations:
    - namespace: kube-system
      serviceAccountName: aws-load-balancer-controller
      roleName: pc-role-lbc
      permissionPolicyARNs: [arn:aws:iam::${ACCOUNT_ID}:policy/pc-policy-lbc]
    - namespace: external-secrets
      serviceAccountName: external-secrets
      roleName: pc-role-eso
      permissionPolicyARNs: [arn:aws:iam::${ACCOUNT_ID}:policy/pc-policy-eso]

# 감사 로그 — 운영 기준. 정리 순서 8번(/aws/eks/<클러스터>/cluster 로그 그룹)과 짝
cloudWatch:
  clusterLogging:
    enableTypes: ["audit", "authenticator"]
    logRetentionInDays: 7

managedNodeGroups:
  - name: ${NODEGROUP}
    instanceType: ${NODE_TYPE}
    amiFamily: AmazonLinux2023
    desiredCapacity: ${NODE_COUNT}
    minSize: ${NODE_COUNT}
    maxSize: ${NODE_MAX}
    volumeSize: 50
    volumeType: gp3
    volumeEncrypted: true
    disableIMDSv1: true
    # Pod 가 IMDS 로 노드 역할을 물려받지 못하게 hop limit 1 (EKS Best Practices).
    # 그래서 LBC 는 IMDS 로 VPC·리전을 찾지 못함 → 40-addons.sh 가 Helm 값에 region·vpcId 를 명시한다
    disablePodIMDS: true
    privateNetworking: true
    subnets: [${SUBNET_APP_A}, ${SUBNET_APP_C}]
    # RDS SG 가 출처로 허용하는 SG. 2일차 확인: 노드 ENI 에 클러스터 SG 와 함께 붙었는지
    securityGroups:
      attachIDs: [${SG_NODE}]
    labels: { pc/role: app }
    tags:
      Project: ${TAG_PROJECT}
      Owner: ${PC_OWNER}
      Env: ${TAG_ENV}
