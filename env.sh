# 모든 스크립트가 맨 처음 source 하는 공통 변수
# 사용: source ./env.sh   (저장소 루트에서)
set +H   # '!' 히스토리 확장 끔 — RDS 비밀 이름 rds!db-... 때문에 필요

export PC_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export AWS_REGION=ap-northeast-2
export AWS_DEFAULT_REGION=ap-northeast-2
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export CLUSTER=pc-eks
export K8S_VERSION=1.36
export LBC_VERSION=v3.6.0          # IAM 정책 태그
export LBC_CHART_VERSION=3.6.0
export ECR=${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com
export IMAGE_TAG=${IMAGE_TAG:-1.0.0}   # 불변 태그 — 이미지를 바꾸면 1.0.1, 1.0.2 … 로 올린다

# 스크립트가 만든 리소스 ID는 .state.env 에 쌓인다 (git 에 올리지 않음)
STATE_FILE="$PC_HOME/.state.env"
touch "$STATE_FILE"
source "$STATE_FILE"
save() { echo "export $1=${!1}" >> "$STATE_FILE"; echo "saved $1=${!1}"; }
