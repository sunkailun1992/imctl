# Build: docker build -t wecom-token-proxy . ; run with the environment variables from docs/protocol/wecom-token-proxy.md §4.
FROM maven:3.9-eclipse-temurin-17 AS build
WORKDIR /src
COPY pom.xml .
RUN mvn -q -DskipTests dependency:go-offline
COPY src ./src
RUN mvn -q -DskipTests package

FROM eclipse-temurin:17-jre
WORKDIR /app
RUN useradd -r -u 10001 proxy && mkdir -p /app/data && chown proxy /app/data
COPY --from=build /src/target/wecom-token-proxy-*.jar /app/app.jar
USER proxy
ENV PROXY_DATA_DIR=/app/data PORT=8080
EXPOSE 8080
ENTRYPOINT ["java", "-XX:MaxRAMPercentage=75", "-jar", "/app/app.jar"]
