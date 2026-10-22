apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig
metadata:
  name: ${CLUSTER}
  region: ${AWS_REGION}
  version: "${K8S_VERSION}"
  tags:
    Project: petclinic
iam:
  withOIDC: true          # IRSA(Pod 단위 IAM 역할)에 필요
vpc:
  id: ${VPC_ID}
  subnets:
    public:
      ap-northeast-2a: { id: ${SUBNET_PUB_A} }
      ap-northeast-2c: { id: ${SUBNET_PUB_C} }
    private:
      ap-northeast-2a: { id: ${SUBNET_APP_A} }
      ap-northeast-2c: { id: ${SUBNET_APP_C} }
addons:
  - name: vpc-cni
  - name: coredns
  - name: kube-proxy
  - name: metrics-server  # HPA CPU 지표용
managedNodeGroups:
  - name: ng-app
    instanceType: t3.large
    amiFamily: AmazonLinux2023
    minSize: 0
    maxSize: 4
    desiredCapacity: 2
    volumeSize: 30
    privateNetworking: true
    subnets: [${SUBNET_APP_A}, ${SUBNET_APP_C}]
    labels: { pc/role: app }
    tags: { Project: petclinic }
