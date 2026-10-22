# PetClinic 3-Tier on Amazon EKS

중간 프로젝트의 PetClinic 3-tier(Nginx → Tomcat → MySQL)를 EKS 위의 컨테이너로 옮긴 개인 프로젝트.
web · was 는 각각 컨테이너(ECR), DB 는 Amazon RDS MySQL 로 둔다.

```
인터넷 ─▶ ALB (pc-alb, LBC Ingress, target-type ip)
           │  퍼블릭 서브넷 2a/2c
           ▼
        web  Deployment ×2~6 (Nginx — 정적 파일 직접 응답, 나머지 프록시)   ┐
           ▼  Service web:80 → was:8080                                       ├ 앱 서브넷 2a/2c (EKS 노드 ng-app)
        was  Deployment ×2~4 (Tomcat 11 + ROOT.war)                          ┘
           ▼  3306 (클러스터 SG 에서만 허용)
        RDS MySQL 8.4 (pc-rds)                                                  DB 서브넷 2a/2c (인터넷 경로 없음)
```

| 항목 | 값 |
|---|---|
| 소스 | [spring-framework-petclinic](https://github.com/spring-petclinic/spring-framework-petclinic) main, `-PMySQL` |
| 리전 | ap-northeast-2 (2a · 2c) |
| EKS | `pc-eks` 1.36, 관리형 노드그룹 `ng-app` t3.large × 2 |
| 이미지 | ECR `pc-web`, `pc-was` — 불변 태그 `1.0.0`, 푸시 시 스캔 |
| DB | `pc-rds` MySQL 8.4 db.t3.small, 비밀번호는 RDS 가 Secrets Manager 에 생성·보관 |
| 확장 | HPA (web CPU 60%, was CPU 70%) + PDB |

## 디렉터리

```
env.sh                 공통 변수 + save() — 만든 리소스 ID 는 .state.env 에 누적
infra/cluster.yaml.tpl eksctl 클러스터 설정 (envsubst 로 치환)
docker/web/            Nginx 이미지 (Dockerfile, default.conf.template)
docker/was/            Tomcat 이미지 (Dockerfile, pc-entrypoint.sh)
k8s/                   was · web · Ingress · HPA/PDB 매니페스트
scripts/00~06          단계별 구축 스크립트
scripts/stop|start     매일 노드 0대 + RDS 중지 / 재개
scripts/destroy.sh     전부 삭제
```

## 실행 순서 (배스천 EC2, Amazon Linux 2023)

배스천에는 이 작업을 할 IAM 권한(역할 또는 `aws configure`)이 있어야 한다.

```bash
git clone <이 저장소> ~/pc && cd ~/pc
chmod +x scripts/*.sh

./scripts/00-install-tools.sh   # 1회. 끝나면 재접속 (docker 그룹 적용)
./scripts/01-vpc.sh             # Day 1 — VPC · 서브넷 6 · IGW · NAT · 라우팅
./scripts/02-cluster.sh         # Day 1 — EKS (15~25분)
./scripts/03-addons.sh          # Day 1 — AWS Load Balancer Controller
./scripts/04-rds.sh             # Day 2 — RDS (10~25분, 기다리는 동안 05 진행)
./scripts/05-build-push.sh      # Day 2~3 — WAR 빌드 · web/was 이미지 · ECR 푸시
./scripts/06-deploy.sh          # Day 4 — 배포 · ALB · HPA → 출력된 http://<ALB 주소> 접속

./scripts/stop.sh               # 매일 종료 시
./scripts/start.sh              # 다음 날 시작 시
./scripts/destroy.sh            # 프로젝트 종료 시
```

새 터미널에서 직접 명령을 칠 때는 먼저 `source ~/pc/env.sh` — 어제 만든 ID 가 모두 되살아난다.

## 동작 확인

```bash
kubectl -n petclinic get pods -o wide                  # web 2 · was 2, 2a/2c 에 분산
curl -sI http://$ALB_DNS/ | grep -i x-app-version     # 응답한 web 버전
```
브라우저에서 `http://<ALB 주소>` → Find Owners → Add Owner → 저장 (DB 쓰기 확인).

## 설계 메모

- **web 이 정적 파일을 직접 응답** — WAR 의 `resources/` 를 Nginx 이미지에 넣어 Tomcat 부하를 줄인다.
- **DB 비밀번호가 이미지·로그에 남지 않음** — WAR 에는 기본값만 있고, 실행 시 Secret → 환경 변수 → `catalina.properties` 로 덮어쓴다. `CATALINA_OPTS -D` 를 쓰면 Tomcat 시작 로그와 `ps` 에 그대로 찍힌다.
- **was 는 1개로 먼저 기동** — 앱이 시작 시 `schema.sql`/`data.sql` 을 실행하므로 동시에 여러 개가 초기화하지 않게 한다.
- **NAT 1개** — 비용 절감. 2a 장애 시 2c 노드의 외부 통신(이미지 pull 등)이 끊기는 것은 감수.

## 확장 후보 (핵심 완료 후)

- [ ] HTTPS — 도메인 + ACM + Route 53
- [ ] External Secrets Operator — Secrets Manager → K8s Secret 자동 동기화 (RDS 비밀 7일 자동 교체 대응)
- [ ] kube-prometheus-stack — Grafana 대시보드, JMX Exporter 로 Tomcat 지표
- [ ] k6 부하 테스트 → HPA 확장 증빙
- [ ] Karpenter — 노드 자동 확장
- [ ] Fluent Bit → CloudWatch Logs
