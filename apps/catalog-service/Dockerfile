# GKE node pools here are e2-standard-2/e2-small (amd64) — pin the platform so this
# still produces a runnable image when built on an arm64 host (e.g. Apple Silicon).
# --- Build stage ---
FROM --platform=linux/amd64 maven:3.9-eclipse-temurin-17 AS build
WORKDIR /build
COPY pom.xml .
COPY src ./src
RUN mvn -q -DskipTests package

# --- Runtime stage ---
FROM --platform=linux/amd64 eclipse-temurin:17-jre-alpine
RUN addgroup -S app && adduser -S app -G app
WORKDIR /app
COPY --from=build /build/target/app.jar app.jar
RUN chown -R app:app /app
USER app
EXPOSE 8080
ENTRYPOINT ["java", "-jar", "app.jar"]
