# orders-service

Demo REST service backed by Postgres (via Cloud SQL in GKE, through a
`cloud-sql-proxy` sidecar). Built with Java 17 + Spring Boot 3 + Maven.

## Endpoints

- `GET /api/orders` - list all orders
- `POST /api/orders` - create an order from `{"product": "...", "quantity": N}`
- `GET /api/orders/{id}` - get one order, 404 if not found
- `GET /actuator/health/liveness` / `GET /actuator/health/readiness` - k8s probes
  (readiness reflects real DB connectivity via Spring Boot's DataSource health
  indicator)
- `GET /actuator/prometheus` - Prometheus metrics

## Configuration / env var contract

This app does not contain any GCP-specific code. In the k8s Deployment
(`k8s/base/orders-service/deployment.yaml`) it runs alongside a
`cloud-sql-proxy` sidecar container that listens on `127.0.0.1:5432` in the
same pod, and the app just talks to it like a normal Postgres server.

Configuration comes from:

- ConfigMap `orders-service-config` (via `envFrom`): `APP_NAME`,
  `SERVER_PORT=8080`, `DB_HOST=127.0.0.1`, `DB_PORT=5432`, `DB_NAME=orders`
- Secret `orders-db-credentials` (via `env`/`secretKeyRef`): `DB_USER` (key
  `username`), `DB_PASSWORD` (key `password`)

`application.yml` builds the JDBC URL from these:

```
jdbc:postgresql://${DB_HOST:127.0.0.1}:${DB_PORT:5432}/${DB_NAME:orders}
```

with `spring.datasource.username=${DB_USER:orders_app}` and
`spring.datasource.password=${DB_PASSWORD:}`. All have local defaults so the
app also runs standalone against a local Postgres without any env vars set.

Schema management uses `spring.jpa.hibernate.ddl-auto=update` (simplest
option for a single-entity demo - Hibernate creates/updates the `order` table
automatically on boot; no migration tooling needed).

## Build and run locally

Requires JDK 17, Maven, and a local Postgres (or just rely on
`ddl-auto=update` against any reachable Postgres instance):

```bash
createdb orders   # if running Postgres locally
mvn -DskipTests package
DB_HOST=127.0.0.1 DB_PORT=5432 DB_NAME=orders DB_USER=postgres DB_PASSWORD=postgres \
  java -jar target/app.jar
```

```bash
curl http://localhost:8080/api/orders
curl -X POST http://localhost:8080/api/orders \
  -H 'Content-Type: application/json' \
  -d '{"product":"Wireless Mouse","quantity":2}'
curl http://localhost:8080/actuator/health
```

## Build the container image

```bash
docker build -t orders-service:latest .
```

## Logging

Same JSON-to-stdout setup as catalog-service (`logback-spring.xml` via
`logstash-logback-encoder`), with a `severity` field matching Cloud Logging's
structured logging convention. Roughly 1-in-20 `POST /api/orders` requests
also emit a simulated ERROR log (the order is still created and 201 is still
returned) - demo-data generation only, so downstream error-rate
dashboards/queries have non-zero data.
