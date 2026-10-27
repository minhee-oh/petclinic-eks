#!/bin/bash
# 관리 EC2 에서 실행되는 부분 — 직접 실행하지 않는다. scripts/60-build-push.sh 가 SSM Run Command 로 보낸다
# 보내는 쪽이 앞에 붙여 주는 값: ECR, IMAGE_TAG, APP_REF, TRIVY_IMAGE, MAVEN_IMAGE, MYSQL_DRIVER, 그리고 빌드 컨텍스트 파일(base64)
# 순서: 소스 → WAR(Maven 컨테이너) → 이미지 2개 → Trivy 관문(CRITICAL·수정 가능 → 중단, push 안 함) → ECR push
set -euo pipefail
export AWS_DEFAULT_REGION=ap-northeast-2
: "${ECR:?}" "${IMAGE_TAG:?}" "${APP_REF:?}" "${TRIVY_IMAGE:?}" "${MAVEN_IMAGE:?}" "${MYSQL_DRIVER:?}"
W=/opt/pc-build
mkdir -p $W && cd $W

step() { echo; echo "== $*"; }

step "source ($APP_REF)"
command -v git >/dev/null || dnf -y -q install git >/dev/null
[ -d app/.git ] || git clone -q https://github.com/spring-petclinic/spring-framework-petclinic.git app
git -C app fetch -q origin
git -C app checkout -q -- . 2>/dev/null || true   # 지난 실행의 pom 수정 되돌림
git -C app checkout -q --detach "$APP_REF"
git -C app log -1 --format='petclinic commit: %H %ad %s' --date=short

# 원본 pom 버그: MySQL 프로필이 mysql:mysql-connector-java:8.1.0 을 요구하지만 옛 좌표는 8.0.33 이 마지막(8.1.0 없음)
# → 새 좌표 com.mysql:mysql-connector-j 로 바꾸고 버전은 -Dmysql-driver.version 으로 준다
sed -i -e 's#<groupId>mysql</groupId>#<groupId>com.mysql</groupId>#' \
       -e 's#<artifactId>mysql-connector-java</artifactId>#<artifactId>mysql-connector-j</artifactId>#' app/pom.xml
grep -q '<artifactId>mysql-connector-j</artifactId>' app/pom.xml || { echo "STOP: pom patch failed"; exit 1; }
echo "pom patched: com.mysql:mysql-connector-j:$MYSQL_DRIVER"

# 원본 버그 2: pom 이 resources 를 Maven 필터링 → ${jdbc.url}·username·password 가 빌드 때 localhost·petclinic 으로 박힌다
#   → 실행 시 시스템 속성(pc-entrypoint.sh)이 끼어들 수 없음(3-7 트러블슈팅). pom 에 없는 키 pc.jdbc.* 로 바꾸면 필터링되지 않는다
# 같이: tomcat-jdbc 풀 상한(기본 maxActive 100 → 8, 기획서 DB 연결 상한 53 의 전제) + 빌려줄 때 검증(RDS 장애 조치 후 끊긴 연결)
DS=app/src/main/resources/spring/datasource-config.xml
sed -i -e 's#\${jdbc\.url}#${pc.jdbc.url}#' -e 's#\${jdbc\.username}#${pc.jdbc.username}#' \
       -e 's#\${jdbc\.password}#${pc.jdbc.password}"\n          p:maxActive="8" p:maxIdle="8" p:minIdle="2" p:initialSize="2" p:maxWait="5000"\n          p:testOnBorrow="true" p:validationQuery="SELECT 1" p:validationInterval="30000#' $DS
[ "$(grep -o '\${pc\.jdbc\.' $DS | wc -l)" = 3 ] && grep -q 'p:maxActive="8"' $DS || { echo "STOP: datasource patch failed"; exit 1; }
echo "datasource patched: pc.jdbc.* placeholders, pool maxActive=8"

# 같은 태그가 이미 있으면 멈춘다 (IMMUTABLE — 덮어쓰기 불가, 다시 빌드하려면 태그를 바꾼다)
for R in pc-web pc-was; do
  if aws ecr describe-images --repository-name $R --image-ids imageTag=$IMAGE_TAG >/dev/null 2>&1; then
    echo "STOP: $R:$IMAGE_TAG already exists (IMMUTABLE) - rerun with a new IMAGE_TAG"; exit 2
  fi
done

step "WAR (Maven container, -PMySQL, tests skipped)"
mkdir -p /root/.m2
docker run --rm -v $W/app:/src -v /root/.m2:/root/.m2 -w /src "$MAVEN_IMAGE" \
  mvn -B -q -PMySQL -Dmysql-driver.version=$MYSQL_DRIVER -DskipTests package
ls -lh app/target/petclinic.war
# 필터링 뒤에도 자리 표시가 남았는지 (localhost 가 박히면 실행 시 덮어쓸 수 없다)
grep -q 'p:url="\${pc.jdbc.url}"' app/target/petclinic/WEB-INF/classes/spring/datasource-config.xml \
  || { echo "STOP: built datasource-config.xml has no pc.jdbc.url placeholder"; exit 1; }
echo "built WAR keeps \${pc.jdbc.*} placeholders"

step "build context"
rm -rf ctx && mkdir -p ctx/web ctx/was
echo "$CTX_WEB_DOCKERFILE"  | base64 -d > ctx/web/Dockerfile
echo "$CTX_WEB_TEMPLATE"    | base64 -d > ctx/web/default.conf.template
echo "$CTX_WAS_DOCKERFILE"  | base64 -d > ctx/was/Dockerfile
echo "$CTX_WAS_ENTRYPOINT"  | base64 -d > ctx/was/pc-entrypoint.sh
cp -r app/target/petclinic/resources ctx/web/resources
cp app/target/petclinic.war ctx/was/ROOT.war

step "docker build"
docker build -q --pull --build-arg APP_VERSION=$IMAGE_TAG ${WEB_BASE:+--build-arg BASE_IMAGE=$WEB_BASE} -t $ECR/pc-web:$IMAGE_TAG ctx/web
docker build -q --pull -t $ECR/pc-was:$IMAGE_TAG ctx/was
docker images --format '{{.Repository}}:{{.Tag}}  {{.Size}}' | grep ":$IMAGE_TAG"

step "Trivy gate (CRITICAL, fixable only)"
mkdir -p /root/.cache/trivy
gate=0
for R in pc-web pc-was; do
  echo "-- $R"
  # --table-mode detailed: 요약 표(jar 마다 한 줄)를 빼야 SSM 출력 한도 24,000자 안에 들어간다(3-5 트러블슈팅)
  docker run --rm -v /var/run/docker.sock:/var/run/docker.sock -v /root/.cache/trivy:/root/.cache/trivy \
    "$TRIVY_IMAGE" image --quiet --severity CRITICAL --ignore-unfixed --exit-code 1 \
    --format table --table-mode detailed $ECR/$R:$IMAGE_TAG 2>&1 && rc=0 || rc=$?
  echo "-- $R exit=$rc"   # 저장소별 결과 (앞 저장소 실패가 뒤 저장소 표시에 번지지 않게)
  [ $rc = 0 ] || gate=1
done
if [ $gate = 1 ]; then
  echo "STOP: Trivy gate failed - fixable CRITICAL vulnerabilities. NOT pushed"; exit 1
fi
echo "Trivy gate passed"

step "ECR push"
aws ecr get-login-password | docker login -u AWS --password-stdin $ECR >/dev/null
docker push -q $ECR/pc-web:$IMAGE_TAG
docker push -q $ECR/pc-was:$IMAGE_TAG
docker logout $ECR >/dev/null   # ECR 토큰(12시간)을 /root/.docker/config.json 에 남기지 않는다
for R in pc-web pc-was; do
  aws ecr describe-images --repository-name $R --image-ids imageTag=$IMAGE_TAG \
    --query 'imageDetails[0].[repositoryName,imageTags[0],imageDigest,imageSizeInBytes]' --output text
done

# 디스크 30GB — 오래된 빌드 이미지 정리 (캐시 레이어는 남김)
docker image prune -f >/dev/null
df -h / | tail -1
