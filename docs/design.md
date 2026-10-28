# PetClinic on EKS — 기획서

> **상태: 완료 (2026-10-26 구축·검증·철거 반영).** 이 문서는 설계와 그 이유, 실제 결과를 함께 적는다. 보고서는 Notion "AWS EKS 기반 PetClinic 3티어 서비스 구축·운영 보고서"이고.
> 실값(계정 ID·ARN·비밀번호·키)은 넣지 않는다. `<ACCOUNT_ID>`, `<OWNER>` 같은 자리표시자만 쓴다.

---

## 1. 목표와 범위

| 항목 | 내용 |
|------|------|
| 목표 | spring-framework-petclinic(WAR)을 AWS EKS 위 3티어(web · was · DB)로 운영 |
| 설계 기준 | **실제 운영 서비스로 가정.** 편의를 위한 선택은 운영 기준으로 설명될 때만 채택 |
| 과제 조건 | web·was 각각 컨테이너(ECR), DB 는 컨테이너 밖(RDS), 외부 접속 확인, 보고서(PDF) |
| 범위 밖 | MSA 판(spring-petclinic-cloud), 퍼블릭 도메인·HTTPS, Pod 안 DB, 별도 모니터링 스택 |
| 기간 | 2026-10-22 \~ 10-26 (보고서 마감 10-28 14:00) |

- **핵심(필수):** 네트워크 · EKS · RDS · 비밀 관리 · 이미지 파이프라인 · 배포 · 외부 접속 · 무중단·장애 검증 → 모두 완료
- **선택:** 수직 카나리 · PITR 복구 리허설 · RDS Proxy 비교 → 완료. CI 빌드 · Container Insights · NodePort 비교 → 하지 않음(보고서 7장)

---

## 2. 아키텍처

토폴로지 그림: `diagrams/target-topology.drawio`

### 2.1 네트워크 — 서울(ap-northeast-2), AZ a·c, VPC `10.0.0.0/16`

| 구역 | a / c | 들어가는 것 | 기본 경로 |
|------|------|------|------|
| public | 10.0.0.0/24 · 10.0.1.0/24 | ALB, NAT(AZ 마다 1개) | IGW |
| private-app | 10.0.10.0/24 · 10.0.11.0/24 | EKS 노드 2대 | 같은 AZ 의 NAT |
| private-db | 10.0.20.0/24 · 10.0.21.0/24 | RDS(Multi-AZ), RDS Proxy | 없음(local 만) |
| private-mgmt | 10.0.30.0/24 · 10.0.31.0/24 | SSM 관리 EC2(a), EKS 컨트롤 플레인 ENI(a·c) | 같은 AZ 의 NAT |

- **NAT 는 AZ 마다 1개.** 리전 NAT 게이트웨이는 쓰지 않았다. AZ 2개 고정이라 자동 AZ 확장이 필요 없고, ALB 때문에 퍼블릭 서브넷이 어차피 필요하며, AZ 장애 시 동작이 문서로 확인되는 쪽은 존별 NAT 다(EKS Best Practices "zone-independent architecture").
- **S3 게이트웨이 엔드포인트**를 app·mgmt 라우트 테이블에 연결했다. ECR 레이어 다운로드가 NAT 를 거치지 않는다.
- **격리는 SG 와 NetworkPolicy 가 한다.** 서브넷은 인터넷 경로 유무만 나눈다.

| SG 규칙 | 관리 |
|------|------|
| ALB → Pod 8080 | LBC 자동 |
| `pc-sg-mgmt` → 클러스터 SG 443 | `30-cluster.sh` |
| `pc-sg-node` · `pc-sg-mgmt` · `pc-sg-proxy` → `pc-sg-rds` 3306 | `10-network.sh`, `76-rds-proxy.sh` |
| `pc-sg-mgmt` 인바운드 | 없음 (SSM 만) |

### 2.2 요청 흐름

```
인터넷 → ALB (public, HTTP 80, ip 대상) → web Pod (nginx :8080, /healthz)
       → was Service → was Pod (Tomcat 11, ROOT.war)
       → db Service (ExternalName) → [RDS Proxy] → RDS MySQL 8.4 Multi-AZ
```

### 2.3 구성 요소와 선택 이유

| 영역 | 선택 | 이유 |
|------|------|------|
| 클러스터 | EKS 1.36, **프라이빗 엔드포인트만**, 컨트롤 플레인 ENI 는 mgmt 서브넷 | API 를 인터넷에 내놓지 않는다. 생성 중에만 내 공인 IP /32 로 열고 닫는다 |
| 노드 | 관리형 노드 그룹 m7i-flex.xlarge × 2 (AZ 마다 1대) | HPA 최대(2.4 vCPU)를 노드 1대가 받는 N+1 |
| 외부 노출 | Gateway API + LBC(ALB), ip 대상 + readiness gate. 등록 해제 30초, `preStop` 15초 \< 30초 ≤ 종료 유예 45초 | 롤링 중 ALB 가 준비 안 된·종료 중인 Pod 로 보내지 않게. 클러스터 안 프록시 Pod 가 필요 없다 |
| web → was | nginx upstream `keepalive 32`, `keepalive_timeout 15s`(\< Tomcat 20초) | 연결 재사용이 없으면 부하 중 임시 포트가 고갈된다(T6, 1.0.3 에서 수정) |
| DB | RDS MySQL 8.4.11, Multi-AZ, db.m8g.large | 버스터블은 크레딧 소진 시 성능이 변해 운영 DB 에 쓰지 않는다 |
| DB 보호 | 삭제 방지, 백업 7일, 최종 스냅샷, 저장 암호화 | 운영 표준. PITR 리허설로 복구까지 확인 |
| DB 전송 암호화 | 파라미터 그룹 `pc-mysql84` 의 `require_secure_transport=1`, 앱 JDBC `sslMode=REQUIRED` | 서버가 강제하므로 클라이언트 설정 실수도 막힌다. 인증서 검증은 개선 과제 |
| DB 경로 | Service `db` (ExternalName) | 앱은 `db` 만 안다. RDS Proxy·복원본 전환이 이 한 줄 교체 |
| 비밀 | Secrets Manager + ESO → K8s Secret → `secretKeyRef` | 원본은 클러스터 밖. master 비밀은 클러스터에 들어오지 않는다 |
| 앱 DB 설정 | `datasource-config.xml` 자리표시 `${pc.jdbc.*}` | 원래 키 `${jdbc.*}` 는 Maven 필터링으로 빌드 때 값이 WAR 에 박혔다(T2·T3) |
| 스키마 | 초기화 Job (SQL 은 ConfigMap, 마이그레이션 계정, 이름에 해시) | 앱 계정은 DML 만. 앱 기동과 스키마 변경을 분리 |
| 이미지 관문 | push **전** Trivy(CRITICAL·수정 가능 → 차단), ECR 태그 변경 불가 + 향상된 스캔 | 나쁜 이미지가 저장소에 들어가지 않게. 직접 `docker push` 우회는 개선 과제 |
| 확장 | was·web HPA 2\~4 (CPU 50%), PDB minAvailable 1, zone topologySpread + `matchLabelKeys`, `replicas` 필드 없음 | DB 연결 상한 (4 + surge 1 + canary 1) × 풀 8 + 관리 5 = **53** ≪ 실측 `max_connections` 630 |
| 네트워크 정책 | 기본 차단 + ALB→web, web→was, was·초기화 Job→DB 서브넷 3306, DNS 53. vpc-cni `enableNetworkPolicy: "true"` | 이 설정이 없으면 NetworkPolicy 가 아무것도 막지 않는다 |
| Pod IAM | EKS Pod Identity (LBC·ESO 만) | OIDC·신뢰 정책 관리 없이 서비스 계정에 역할을 묶는다 |
| 노드 IMDS | IMDSv2 필수 + hop limit 1, LBC 에 `region`·`vpcId` 직접 지정 | Pod 가 노드 역할을 물려받지 못하게 |
| 클러스터 접근 | `authenticationMode: API` (액세스 엔트리만) | 운영이라면 생성자 관리자 권한도 회수 |
| Pod 보안 | PSS `enforce: baseline`, `warn·audit: restricted` | restricted 위반은 경고로 드러낸다(초기화 Job 경고 0건) |
| 모니터링 | metrics-server + CloudWatch 기본 지표 + curl 루프 | 검증 항목을 모두 측정할 수 있고 스택 운영 부담이 없다 |

### 2.4 버전

| 대상 | 버전 |
|------|------|
| EKS · 노드 | 1.36 (노드 v1.36.5, Amazon Linux 2023) |
| RDS | MySQL 8.4.11 |
| AWS Load Balancer Controller | Helm 차트 3.5.0 / 앱 v3.5.0 |
| Gateway API CRD | v1.6.0 |
| External Secrets Operator | Helm 차트 2.12.0 |
| metrics-server | EKS 애드온 v0.9.0-eksbuild.14 (`cluster.yaml.tpl` 에 명시 — T11) |
| EKS 애드온 | vpc-cni, coredns, kube-proxy, eks-pod-identity-agent |
| 이미지 | `tomcat:11.0.27-jre21-temurin-noble`, `nginxinc/nginx-unprivileged:1.30.6-alpine` |
| MySQL 드라이버 | `com.mysql:mysql-connector-j` 26.7.0 |

버전은 "릴리스 후 2주가 지난 최신판"을 기준으로 골랐다. Helm 은 LBC·ESO 두 개에만 쓴다.

---

## 3. 운영 방식

### 3.1 작업 경로

- 로컬 PC(Git Bash)에서 스크립트를 실행한다. kubectl 은 SSM 포트 포워딩(`127.0.0.1:8443` → EKS 프라이빗 엔드포인트 443)으로 붙는다.
- 관리 EC2 에서 할 일(DB 계정, 이미지 빌드·Trivy·push)도 로컬 스크립트가 SSM Run Command 로 보낸다. 로컬에는 Docker 가 없다.
- 자격 증명은 임시 자격 증명만 쓰고 저장소·문서에 남기지 않는다.

### 3.2 야간 중지·기동

| 순서 | 중지 (`stop.sh`) | 기동 (`start.sh`) |
|------|------|------|
| 1 | 앱 Deployment 의 replicas 를 주석 `pc/replicas-before-stop` 에 기록 → 0 | 관리 EC2 시작 → SSM Online |
| 2 | 노드 그룹 0 (15분 안에 줄지 않으면 막힌 PDB 를 기록) | RDS 시작 → available |
| 3 | RDS 중지 | 노드 그룹 2 → Ready |
| 4 | 관리 EC2 중지 (터널 경로라 마지막) | 주석 값으로 replicas 복구 (kube-system·ESO → was → web) |
| 5 | — | 대상 healthy + ALB 200 = 서비스 복귀 (V8: 10분 16초) |

밤에도 과금되는 것: EKS 컨트롤 플레인, NAT 2개, EIP 2개, ALB, RDS 스토리지(시간당 약 $0.27). 다시 만들면 NAT·EIP·ALB 주소가 바뀌므로 철거 때만 지운다.

### 3.3 이름·태그

- 규칙 `pc-<종류>-<역할>-<AZ>`. 접두사를 짧게 잡은 것은 ALB·대상 그룹 이름이 32자로 제한되기 때문이다. 네임스페이스는 `petclinic`.
- 태그 `Project=petclinic`, `Owner=<OWNER>`, `Env=prod`. 비용 할당 태그는 교육 계정이 멤버 계정이라 활성화할 수 없었다. 비용은 서비스별·일별로 본다.
- 이미지 태그 `<앱 버전>-<커밋 7자리>` (예: `1.0.3-cf39292`).

---

## 4. 검증 계획과 결과

무중단 측정은 0.5\~1초 간격 curl 루프(요청 시간 초과 5초)로 했다. 원본 기록은 `logs/verify-20261026/` 에 있다.

| # | 항목 | 방법 | 통과 기준 | 결과 |
|---|------|------|------|------|
| V1 | 외부 접속 | ALB DNS 로 브라우저·curl | 펫 등록·조회 | ✅ 200 |
| V2 | 무중단 롤링 | 루프 중 이미지 교체 | 5xx 0, HPA 변화 없음 | ✅ 3회, 200 아님 0·0·0 (1차에 AZ 쏠림 발견 → T5 수정) |
| V3 | HPA | k6 300초 · VU 50 | 2 → 4 → 2 | ✅ 실패 0 / 474,912, p95 92ms (1차 Target 5XX 3.5% → T6 수정) |
| V4 | 커넥션 풀 상한 | 부하 중 Pod IP 별 연결 집계 | Pod 당 ≤ 8 | ✅ 8·8·8·8 (계획의 `DB_POOL_MAX=2` 대신 실제 설정으로 시험) |
| V5 | NetworkPolicy | 임시 Pod 로 허용·차단 5경로 | 의도대로 | ✅ |
| V6 | RDS 장애 조치 | `--force-failover` ① 직접 ② Proxy 경유 | 복구 후 정상, 비교 | ✅ ① 약 10초 ② 약 12\~13초, Pod 재시작 0 |
| V7 | 노드 drain | 노드 1대 drain | PDB 유지, 서비스 지속 | ✅ 200 아님 0 |
| V8 | 야간 중지 후 복귀 | `start.sh` | 같은 상태로 복귀 | ✅ 10분 16초, ALB 주소 동일 |
| V9 | 이미지 관문 | 옛 nginx 베이스로 `60-build-push.sh` | push 전에 중단 | ✅ CRITICAL 9건 → `NOT pushed` |

---

## 5. 일정 (실제)

| 일차 | 날짜 | 한 일 |
|------|------|------|
| 1 | 10/22 | 기획서·작업지시서, 스크립트 작성, 로컬 Maven 빌드로 원본 pom 문제 발견(T1·T2) |
| 2 | 10/23, 10/25 오후 | VPC → 관리 EC2 → RDS(콘솔, 스크립트와 같은 값) → EKS → 터널 → 애드온 → Gateway 샘플 → 야간 중지 |
| 3 | 10/25 (예비일 사용) | 비밀·DB 계정·ESO → ECR → 빌드(1.0.0 실패 → 1.0.1) → 배포 → V1 |
| 4 | 10/26 | V8 → V2\~V9 → 증빙 → 1차 철거 → 재구축(전부 스크립트, 1차 철거 후 선택 실험을 위해 추가) → 카나리·PITR·RDS Proxy → 최종 철거 |
| 5 | 10/27\~28 | 보고서, Cost Explorer 실제 비용, 14:00 제출 |

---

## 6. 철거 순서 (`destroy.sh`)

터미널에서 클러스터 이름(`pc-eks`)을 입력해야만 실행된다.

1. 카나리·HTTPRoute·Gateway → ALB·대상 그룹이 사라질 때까지 대기
2. Helm 릴리스(ESO·LBC)
3. 노드 그룹 → 클러스터 (터널은 이때까지 열어 둔다 — T9)
4. RDS Proxy → PITR 복원본(있으면) → RDS: 삭제 방지 해제 후 최종 스냅샷과 함께 삭제
5. IAM 역할·정책 (LBC·ESO·Proxy·관리 EC2)
6. 관리 EC2 → ECR 저장소
7. Secrets Manager: 복구 기간 7일로 삭제
8. CloudWatch 로그 그룹, DB 서브넷 그룹·파라미터 그룹
9. NAT → EIP → S3 엔드포인트·SG·라우트 테이블·IGW·서브넷 → VPC
10. 남은 ENI·과금 자원 0 확인

결과: 1차(16:39\~16:53)는 T9 로 재시도 후 완료했고, 최종(20:11\~20:36)은 한 번에 끝났다. 남긴 것은 최종 스냅샷 2개뿐이고 **2026-11-04 에 삭제**한다.

---

## 7. 위험과 대응

| 위험 | 대응 | 실제 |
|------|------|------|
| 자격 증명 지연 | 1일차에 해결, 안 되면 강사 문의 | 1일차 `InvalidClientTokenId` → 2일차에 해결 |
| 컨트롤 플레인 ENI 가 app 서브넷에 생김 | `30-cluster.sh` 가 mgmt 로 옮기고 확인 | 스크립트가 처리 |
| SSM 세션 유휴 제한 | kubectl 직전 `tunnel_up` 으로 재연결 | 스크립트가 처리 |
| LBC Gateway 가 가중치·헤더 미지원 | 2일차 샘플로 확인, 실패 시 Ingress | 샘플 통과(88:12, 헤더 20/20) → 채택 |
| 생성 중 퍼블릭 엔드포인트 노출 | 생성 직후 닫음, 재실행 시 먼저 닫음 | 재구축 중 PC 종료로 /32 가 열린 채 남음 → 재실행으로 닫음(T10) |
| 야간 drain 이 kube-system PDB 에 막힘 | 15분 판정 후 기록 | 막히지 않음. 인터넷 끊김을 막힘으로 오판한 건 있음(T8) |
| 재구축 시 Secrets Manager 이름 충돌 | `restore-secret` 으로 되살림 | `35-secrets-eso.sh` 가 처리 |
| 일정 지연 | 주말 예비일, 선택 항목부터 제외 | 예비일 사용, 선택 3개 완료 |

---

## 8. 개선 과제 (이번 범위 밖)

| 영역 | 지금의 한계 | 개선 |
|------|------|------|
| 이미지 공급망 | 스크립트 관문이라 직접 `docker push` 로 우회 가능 | Kyverno 로 다이제스트 고정·서명 검증 |
| 배포 | 관리 EC2 에서 스크립트 실행 | GitHub Actions(OIDC) → Argo CD, 카나리는 Argo Rollouts |
| 전송 보안 | HTTP 80(도메인 없음), DB 인증서 미검증 | ACM HTTPS, RDS CA 번들 + `VERIFY_IDENTITY` |
| 관측 | `kubectl logs` 뿐, ALB 접근 로그 없음 | Container Insights·Fluent Bit, ALB 로그 → S3, 5xx·커넥션 경보 |
| 경계·Pod 보안 | WAF 없음, PSS restricted 는 경고만 | AWS WAF, restricted 강제 |
| 비밀·접근 | 앱 비밀번호 수동 교체, 생성자 관리자 권한 유지 | 자동 교체, 운영자 역할 액세스 엔트리만 |
| 확장·복구 | 노드 2대 고정, PITR 후 전환 수동 | Karpenter, 복원·전환 스크립트와 정기 리허설 |

## 9. 검토했지만 채택하지 않은 대안

| 대안 | 채택하지 않은 이유 |
|------|------|
| 리전 NAT 게이트웨이 | 2.1 — AZ 2개 고정, 퍼블릭 서브넷 필요, AZ 장애 동작이 문서로 확인되는 쪽은 존별 NAT |
| NLB + ingress-nginx | ALB 가 L7 을 직접 처리하므로 클러스터 안 프록시 Pod 를 따로 운영할 이유가 없음 |
| eksctl 완전 프라이빗 모드 | 관리 EC2 에 클러스터·CloudFormation·IAM 생성 권한이 필요해 최소 권한에 어긋남 |
| EKS Auto Mode | Gateway API·LBC 를 직접 다루는 학습 목표에서 멀어짐 |
| Karpenter | HPA 최대치가 노드 1대 안에 들어가는 N+1 이라 필요 없음 |
| RDS Proxy 상시 사용 | 측정상 장애 조치를 빠르게 하지 않음(V6). Pod 가 늘어 커넥션이 상한이 될 때 도입 |
