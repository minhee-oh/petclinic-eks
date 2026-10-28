# PetClinic 3-Tier on Amazon EKS

spring-framework-petclinic(단일 WAR)을 web(nginx)·was(Tomcat) 컨테이너로 나눠 Amazon EKS에 올리고, DB는 RDS MySQL Multi-AZ에 둔 1인 프로젝트다. 실제 운영 서비스로 가정하고 설계했고, 무중단 배포·자동 확장·DB 장애 조치를 측정으로 확인했다.

**보고서**: [AWS EKS 기반 PetClinic 3티어 서비스 구축·운영 보고서 (PDF)](docs/report.pdf) — 설계 결정과 대안, 검증 V1~V9, 심화 실험, 운영·비용

![전체 아키텍처](diagrams/report/target-topology.png)

## 핵심 결과

- **검증 V1~V9 모두 통과**: V1·V2·V3은 측정으로 문제를 찾아 고친 뒤 다시 측정해 통과했다 (아래 표)
- **부하**: 474,912건 실패 0, p95 92ms (초당 약 1,580 요청), HPA 2→4→2
- **무중단**: 롤링 배포 3회, 노드 drain과 재배치 중 요청 983건에서 200 아닌 응답 0
- **DB 장애 조치**: 앱 영향 약 10초, Pod 재시작 0. RDS Proxy를 넣어도 빨라진다는 근거는 없었다 (연결 집약만 확인)
- **재구축**: 철거 후 같은 날 스크립트만으로 전체 재구축 (약 1시간 40분, PC가 꺼져 멈춘 약 30분 포함)
- **비용**: 실제 약 $32 (Cost Explorer, 10/22~10/27). 야간 중지, 10/26 철거 후 최종 스냅샷만 남김

### 측정으로 찾아 고친 문제

| 검증 | 발견한 문제 | 해결 |
|---|---|---|
| V1 외부 접속 | was 기동 실패: DB 주소가 빌드 때 `localhost`로 고정됨 | 자리표시 키 변경, 1.0.1 재빌드 |
| V2 무중단 롤링 | 롤링 후 web 2개가 한 AZ에 모임 | topologySpread에 `matchLabelKeys`, AZ 분산 확인 |
| V3 부하 | Target 5XX 3.5% | nginx upstream keepalive, 1.0.3에서 0 |

## 구성

```
인터넷 → ALB (Gateway API, ip 대상) → web Pod (nginx) → was Pod (Tomcat 11)
       → db Service (ExternalName) → RDS MySQL 8.4 Multi-AZ (private-db 서브넷)
```

| 영역 | 내용 |
|---|---|
| 네트워크 | VPC 1개, AZ 2개 × 서브넷 4종(public·app·db·mgmt), AZ마다 NAT, S3 게이트웨이 엔드포인트 |
| 클러스터 | EKS 1.36, 프라이빗 API 엔드포인트만, 관리형 노드 그룹 m7i-flex.xlarge × 2, 접속은 SSM 포트 포워딩 |
| 진입 | AWS Load Balancer Controller + Gateway API(HTTPRoute 가중치·헤더 라우팅) |
| 데이터 | RDS MySQL 8.4 db.m8g.large Multi-AZ, TLS 강제, 앱 계정은 DML만 |
| 비밀 | Secrets Manager → External Secrets Operator, Pod IAM은 Pod Identity |
| 이미지 | ECR 불변 태그, push 전 Trivy 관문(CRITICAL이면 중단) |
| 앱 운영 | HPA·PDB·topologySpread, readiness gate, NetworkPolicy 기본 차단, PSS baseline |

![클러스터 안 리소스 관계도](diagrams/report/fig-k8s-resources.png)

## 디렉터리

```
env.sh, scripts/lib.sh   공통 변수·함수 (실값은 .state.env에만, 커밋하지 않음)
scripts/NN-*.sh          구축·배포·검증 스크립트 (아래 순서)
scripts/remote/          관리 EC2에서 SSM Run Command로 실행되는 스크립트
infra/                   eksctl 클러스터 설정 템플릿, ECR 수명 주기 정책
docker/web, docker/was   이미지 (Dockerfile, nginx 설정, 엔트리포인트)
k8s/                     매니페스트 (namespace, secrets, services, was, web, gateway, canary, netpol, db-init Job)
diagrams/report/         보고서 그림과 그 원본(src/)
docs/report.pdf          보고서
docs/design.md           설계 문서(기획서): 결정과 이유, 실제 결과. 스크립트 주석의 "기획서 N.N"은 이 문서의 절이다
```

## 사전 준비

- **도구** (로컬 Windows): Git Bash, AWS CLI v2, Session Manager 플러그인, eksctl, kubectl, Helm. 이미지 빌드는 관리 EC2에서 하므로 로컬 Docker는 필요 없다
- **자격 증명**: AWS CLI 프로필 설정 후 `aws sts get-caller-identity`로 확인
- **태그 소유자**: `export PC_OWNER=<이름>` (저장소에 남기지 않음). 나머지 값(리전 ap-northeast-2, 이름, 버전)은 `env.sh`에 있고, 계정 ID는 실행할 때 조회한다
- **관리자 권한 한 번**: `21-tunnel.sh`가 알려 주는 한 줄을 hosts 파일에 넣어야 kubectl이 붙는다 (API 서버 인증서가 엔드포인트 이름으로 발급돼 있어서)
- **생성 중 노출**: `30-cluster.sh`는 생성하는 20~30분 동안만 API 엔드포인트를 내 공인 IP /32로 열고, 끝나면 프라이빗으로 닫는다
- **비용 주의**: 켜 두면 월 약 $920 (서울 온디맨드 730시간, 보고서 6.4). 쓰지 않을 때는 `stop.sh`, 끝나면 반드시 `destroy.sh`

## 실행 순서

모든 스크립트는 로컬 Git Bash에서 실행한다. 이름 태그로 자원을 먼저 찾고 없을 때만 만들므로, 중간에 끊겨도 다시 실행하면 이어서 진행한다.

```bash
./scripts/01-preflight.sh      # 자격 증명·할당량·AZ·인스턴스 유형 조회만
./scripts/10-network.sh        # VPC·서브넷·NAT·SG
./scripts/20-mgmt-ec2.sh       # 관리 EC2 (SSM 전용, 인바운드 0)
./scripts/31-rds.sh            # RDS Multi-AZ
./scripts/30-cluster.sh        # EKS → 프라이빗 전환
./scripts/21-tunnel.sh         # SSM 포트 포워딩 (kubectl 접속)
./scripts/40-addons.sh         # LBC, Gateway API CRD
./scripts/35-secrets-eso.sh    # 비밀, ESO
./scripts/32-db-bootstrap.sh   # DB 계정 (pc_app, pc_migration)
./scripts/34-ecr.sh            # ECR 저장소
./scripts/60-build-push.sh     # WAR 빌드 → 이미지 → Trivy → push
./scripts/70-deploy.sh         # Secret 동기화 → NetworkPolicy → 초기화 Job → Gateway → 앱, 끝에 ALB 주소 출력
./scripts/90-verify.sh <명령>  # 검증: loop(무중단) · load / unload(k6 부하) · conns(DB 연결) · netpol

./scripts/75-canary.sh         # 수직 묶음 카나리 (up / weight / measure / down)
./scripts/76-rds-proxy.sh      # RDS Proxy 생성(up), DB 경로 전환 (use / direct)
./scripts/77-pitr.sh           # PITR 복구 리허설 (mark / restore / check / delete)
./scripts/stop.sh              # 야간 중지: 앱 0 → 노드 0 → RDS·관리 EC2
./scripts/start.sh             # 기동 (역순, 약 10분)
./scripts/nat.sh status|down|up # 작업 없는 날 NAT 삭제 / 같은 EIP로 재생성 (start.sh 전에 up)
./scripts/destroy.sh           # 전체 철거 (pc-eks 입력 확인)
```

자원을 만들기 전에 각 스크립트 머리의 주석(사용법, 전제 조건)을 먼저 읽는다.

## 범위 밖

HTTPS(도메인 없음), 별도 모니터링 스택. 개선 과제는 보고서 7장에 정리했다.
