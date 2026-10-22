FROM nginx:stable-alpine
ARG APP_VERSION=1.0.0
ENV APP_VERSION=${APP_VERSION}
# 공식 이미지는 시작 시 /etc/nginx/templates/*.template 의 ${APP_VERSION} 같은 환경 변수만 치환한다
COPY default.conf.template /etc/nginx/templates/default.conf.template
# 05-build-push.sh 가 WAR 빌드 결과(target/petclinic/resources)를 여기로 복사해 둔다
COPY resources /usr/share/nginx/html/resources
EXPOSE 8080
