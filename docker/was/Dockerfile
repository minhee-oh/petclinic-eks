FROM tomcat:11.0-jre17
# 공식 이미지의 webapps/ 는 비어 있다 (Manager 앱 미노출). ROOT.war 로 넣으면 주소가 / 가 된다
COPY ROOT.war /usr/local/tomcat/webapps/ROOT.war
COPY --chmod=755 pc-entrypoint.sh /usr/local/bin/pc-entrypoint.sh
ENV JAVA_OPTS="-XX:MaxRAMPercentage=75"
EXPOSE 8080
CMD ["/usr/local/bin/pc-entrypoint.sh"]
