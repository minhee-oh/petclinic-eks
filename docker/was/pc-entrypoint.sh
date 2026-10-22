#!/bin/sh
set -e
: "${DB_HOST:?DB_HOST required}" "${DB_USER:?DB_USER required}" "${DB_PASS:?DB_PASS required}"
esc() { printf '%s' "$1" | sed 's/\\/\\\\/g'; }
# catalina.properties 의 항목은 Tomcat 시작 시 JVM 시스템 속성이 되고,
# datasource-config.xml 이 WAR 안의 jdbc.* 기본값을 이 값으로 덮어쓴다 (system-properties-mode=OVERRIDE)
# CATALINA_OPTS 의 -D 로 넘기면 비밀번호가 시작 로그와 ps 에 그대로 찍히므로 이 방식을 쓴다
cat >> /usr/local/tomcat/conf/catalina.properties <<PROPS
jdbc.url=jdbc:mysql://${DB_HOST}:3306/petclinic?useUnicode=true
jdbc.username=$(esc "$DB_USER")
jdbc.password=$(esc "$DB_PASS")
PROPS
unset DB_PASS
exec catalina.sh run
