# was — Tomcat 11 + petclinic.war
# pom 이 Tomcat ≥ 11.0.18 요구. 11.0.27 = 2026-10 최신 패치(Trivy 관문 통과에 유리), JRE 21(LTS)
FROM tomcat:11.0.27-jre21-temurin-noble
# 공식 이미지의 webapps/ 는 비어 있다(Manager 앱 미노출). ROOT.war 로 넣으면 주소가 / 가 된다
# 1.0.2: OS 패키지 보안 업데이트(Inspector HIGH zlib) + 쓰지 않는 기본 앱 원본(webapps.dist) 제거
RUN apt-get update && apt-get -y upgrade && rm -rf /var/lib/apt/lists/* /usr/local/tomcat/webapps.dist
COPY ROOT.war /usr/local/tomcat/webapps/ROOT.war
COPY --chmod=755 pc-entrypoint.sh /usr/local/bin/pc-entrypoint.sh
# root 로 돌지 않는다 (PSS restricted). 엔트리포인트가 conf/catalina.properties 에 쓰고, Tomcat 이 webapps·logs·work·temp 에 쓴다
RUN useradd -r -u 10001 -g 0 -d /usr/local/tomcat tomcat \
 && chown -R 10001:0 /usr/local/tomcat && chmod -R g=u /usr/local/tomcat
USER 10001
# 힙은 컨테이너 메모리 제한의 70% (나머지는 메타스페이스·스레드 스택·Tomcat 네이티브)
# DNS 캐시 30초 — RDS 장애 조치 때 엔드포인트 IP 가 바뀐다 (JVM 기본은 보안 관리자 없으면 30초지만 명시)
ENV JAVA_OPTS="-XX:MaxRAMPercentage=70 -Dsun.net.inetaddr.ttl=30"
EXPOSE 8080
CMD ["/usr/local/bin/pc-entrypoint.sh"]
