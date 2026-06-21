# catalog-service

Stateless demo REST service with an in-memory product catalog. Built with
Java 17 + Spring Boot 3 + Maven. No external GCP dependencies.

## Endpoints

- `GET /api/catalog` - list all products (JSON array)
- `GET /api/catalog/{id}` - get one product, 404 if not found
- `GET /api/catalog/stress?ms=500` - busy-loop for `ms` milliseconds to generate
  artificial CPU load (used to demo HPA autoscaling)
- `GET /actuator/health/liveness` / `GET /actuator/health/readiness` - k8s probes
- `GET /actuator/prometheus` - Prometheus metrics

## Build and run locally

Requires JDK 17 and Maven (or use the Maven wrapper if added).

```bash
mvn -DskipTests package
java -jar target/app.jar
```

The app listens on port 8080 by default (`server.port`, overridable via the
`SERVER_PORT` env var to match how it's deployed in k8s).

```bash
curl http://localhost:8080/api/catalog
curl http://localhost:8080/api/catalog/1
curl "http://localhost:8080/api/catalog/stress?ms=200"
curl http://localhost:8080/actuator/health
```

## Build the container image

```bash
docker build -t catalog-service:latest .
docker run -p 8080:8080 catalog-service:latest
```

## Logging

Logs are emitted as JSON to stdout (`logback-spring.xml`, via
`logstash-logback-encoder`) with a `severity` field (INFO/WARNING/ERROR, etc.)
matching Cloud Logging's structured logging convention, so Cloud Logging /
BigQuery sinks can filter on it directly. Roughly 1-in-20 requests to
`/api/catalog` also emit a simulated ERROR log (request still returns 200) -
this is demo-data generation only, so downstream error-rate dashboards/queries
have non-zero data.
