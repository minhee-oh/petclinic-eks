#!/bin/sh
set -e
: "${DB_HOST:?DB_HOST required}" "${DB_USER:?DB_USER required}" "${DB_PASS:?DB_PASS required}"
esc() { printf '%s' "$1" | sed 's/\\/\\\\/g'; }
# catalina.properties 의 항목은 Tomcat 시작 시 JVM 시스템 속성이 되고,
# datasource-config.xml 의 ${...} 자리를 이 값으로 채운다 (system-properties-mode=OVERRIDE)
#   접속 정보 키는 pc.jdbc.* — jdbc.url 등은 Maven 필터링으로 빌드 때 값이 박혀 덮어쓸 수 없다 (빌드 스크립트가 키를 바꿈)
# CATALINA_OPTS 의 -D 로 넘기면 비밀번호가 시작 로그와 ps 에 그대로 찍히므로 이 방식을 쓴다
#   sslMode=REQUIRED : 서버도 require_secure_transport=1 이라 TLS 없으면 접속 거부
#   initLocation·dataLocation : 앱은 기동할 때마다 schema.sql·data.sql 을 실행하는데, 앱 계정(pc_app)은 DML 만 있어
#     CREATE 에서 실패한다 → 스키마·데이터는 초기화 Job(마이그레이션 계정)이 맡고, 앱은 무해한 SELECT 1 만 실행
printf 'SELECT 1;\n' > /usr/local/tomcat/conf/pc-noop.sql
cat >> /usr/local/tomcat/conf/catalina.properties <<PROPS
pc.jdbc.url=jdbc:mysql://${DB_HOST}:3306/petclinic?useUnicode=true&sslMode=REQUIRED
pc.jdbc.username=$(esc "$DB_USER")
pc.jdbc.password=$(esc "$DB_PASS")
jdbc.initLocation=file:/usr/local/tomcat/conf/pc-noop.sql
jdbc.dataLocation=file:/usr/local/tomcat/conf/pc-noop.sql
PROPS
unset DB_PASS
exec catalina.sh run
