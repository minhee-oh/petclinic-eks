# 모든 스크립트가 맨 처음 source 하는 공통 변수
# 사용: source ./env.sh   (저장소 루트에서)
# 실값 금지 — 계정 ID·키·비밀번호는 여기 두지 않는다. 계정 ID는 require_aws 가 실행 시 조회한다.
set +H   # '!' 히스토리 확장 끔 — RDS 관리형 비밀 이름 rds!db-... 때문에 필요

export PC_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 리전·AZ
export AWS_REGION=ap-northeast-2
export AWS_DEFAULT_REGION=$AWS_REGION
export PYTHONUTF8=1   # Windows AWS CLI 는 출력을 cp949 로 써서 UTF-8 이 섞이면 실패한다(3-5 트러블슈팅)
export AZ_A=ap-northeast-2a
export AZ_C=ap-northeast-2c

# 이름 — 접두사 pc- (ALB·대상 그룹 이름 32자 제한)
export CLUSTER=pc-eks
export NODEGROUP=pc-ng-app
export NS=petclinic
export RDS_ID=pc-rds
export MGMT_NAME=pc-mgmt

# 버전 고정 (기획서 2.4)
export K8S_VERSION=1.36
export LBC_VERSION=v3.5.0          # IAM 정책·CRD 경로도 이 태그
export LBC_CHART_VERSION=3.5.0
export GATEWAY_API_VERSION=v1.6.0
export METRICS_SERVER_VERSION=v0.9.0
export ESO_CHART_VERSION=2.12.0   # 2026-10-06 릴리스 — 최신(2.14.0, 10-23)은 2주가 안 돼 제외 (3일차 고정)

# 네트워크 (기획서 2.1) — 4구역 × AZ 2개
export VPC_CIDR=10.0.0.0/16
export CIDR_PUB_A=10.0.0.0/24   CIDR_PUB_C=10.0.1.0/24
export CIDR_APP_A=10.0.10.0/24  CIDR_APP_C=10.0.11.0/24
export CIDR_DB_A=10.0.20.0/24   CIDR_DB_C=10.0.21.0/24
export CIDR_MGMT_A=10.0.30.0/24 CIDR_MGMT_C=10.0.31.0/24

# 크기 (기획서 2.3)
export NODE_TYPE=m7i-flex.xlarge
export NODE_COUNT=2               # AZ마다 1대 고정 (N+1)
export NODE_MAX=3                 # 노드 롤링 교체 여유 1대
export MGMT_TYPE=t3.medium
export RDS_CLASS=db.m8g.large     # 운영 기준 — 버스터블(t) 제외
export RDS_ENGINE_VERSION=8.4.11
export RDS_STORAGE_GB=20
export DB_NAME=petclinic

# 태그 — Owner 실값은 셸에서 export PC_OWNER=... 로 넣는다 (저장소에 남기지 않음)
export PC_OWNER=${PC_OWNER:-<OWNER>}
export TAG_PROJECT=petclinic
export TAG_ENV=prod

# 스크립트가 만든 리소스 ID는 .state.env 에 쌓인다 (git 에 올리지 않음)
# 모든 ensure_* 는 이름 태그로 다시 찾으므로, 이 파일이 없어도 재실행은 안전하다
export STATE_FILE="$PC_HOME/.state.env"
touch "$STATE_FILE"
source "$STATE_FILE"
source "$PC_HOME/scripts/lib.sh"
