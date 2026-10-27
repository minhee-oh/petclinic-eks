# web — nginx(정적 파일 + was 프록시)
# nginx-unprivileged: uid 101 로 8080 에서 듣는다 (PSS restricted). 1.30 = stable 계열 최신 패치(2026-10)
# BASE_IMAGE 는 V9(이미지 관문) 시험 때만 바꾼다 — 취약한 옛 이미지를 넣어 Trivy 가 push 전에 막는지
ARG BASE_IMAGE=nginxinc/nginx-unprivileged:1.30.6-alpine
FROM ${BASE_IMAGE}
ARG APP_VERSION=1.0.0
ENV APP_VERSION=${APP_VERSION}
# 프록시할 was Service 이름 — 카나리 web 은 Deployment 의 env 로 was-canary 를 준다
ENV WAS_UPSTREAM=was
# 시작 시 /etc/nginx/templates/*.template 의 ${APP_VERSION} 같은 환경 변수만 치환한다
COPY default.conf.template /etc/nginx/templates/default.conf.template
# 빌드 스크립트가 WAR 빌드 결과(target/petclinic/resources)를 여기로 복사해 둔다
COPY resources /usr/share/nginx/html/resources
EXPOSE 8080
