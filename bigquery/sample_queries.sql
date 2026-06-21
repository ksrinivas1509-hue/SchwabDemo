-- Sample BigQuery queries against the `logs_export` dataset created by
-- terraform/modules/observability and populated by the two log sinks
-- (`sink-app-logs`, `sink-k8s-events`) — see docs/DESIGN.md §5 for why the split
-- between BigQuery (logs) and Cloud Monitoring (metrics, queried directly by
-- Grafana) looks the way it does.
--
-- Table names below assume `use_partitioned_tables = true`, which names the BQ
-- table after the Cloud Logging log type, e.g. container stdout/stderr lands in
-- `logs_export.stdout`/`logs_export.stderr`, Kubernetes events in
-- `logs_export.events`. Run `bq ls logs_export` after a few minutes of traffic to
-- confirm the exact table names in your project before running these (Cloud
-- Logging only creates a table once it has a row to write).
--
-- Render `${PROJECT_ID}` first: `envsubst < bigquery/sample_queries.sql > /tmp/sample_queries.sql`
-- (same envsubst convention used for grafana/helm-values.yaml, see
-- docs/IMPLEMENTATION.md Step 12). Then run queries individually — see
-- docs/IMPLEMENTATION.md Step 13 for why piping the whole file into one
-- `bq query` call doesn't work.

-- =============================================================================
-- 1. Application error rate over time (Grafana panel 1 — BigQuery datasource)
-- =============================================================================
-- Required by the spec as the one panel that's genuinely log-shaped: counts
-- ERROR-level structured log lines against total log volume, per app, per hour.
-- NOTE: apps/*/src/main/resources/logback-spring.xml intends to emit a top-level
-- `severity` field (so Cloud Logging auto-promotes it to LogEntry.severity), via a
-- LogLevelJsonProvider — but that provider isn't actually taking effect (confirmed:
-- jsonPayload only ever contains `level`, never `severity`, and the top-level
-- `severity` BigQuery column is always INFO/DEFAULT regardless of the real log
-- level). Until that's fixed at the source and the apps are rebuilt/redeployed,
-- query `jsonPayload.level` directly instead of the top-level `severity` column —
-- see docs/TROUBLESHOOTING.md for the full writeup.
SELECT
  TIMESTAMP_TRUNC(timestamp, HOUR)                                   AS hour,
  resource.labels.container_name                                    AS app,
  COUNTIF(jsonPayload.level IN ('ERROR', 'WARN'))                    AS error_count,
  COUNT(*)                                                           AS total_count,
  SAFE_DIVIDE(COUNTIF(jsonPayload.level IN ('ERROR', 'WARN')), COUNT(*)) AS error_rate
FROM `${PROJECT_ID}.logs_export.stdout`
WHERE
  resource.type = 'k8s_container'
  AND resource.labels.namespace_name = 'apps'
  AND timestamp > TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 24 HOUR)
GROUP BY hour, app
ORDER BY hour DESC, app;

-- =============================================================================
-- 2. Pod restart counts by namespace (BigQuery fallback for Grafana panel 2)
-- =============================================================================
-- Grafana's panel 2 queries Cloud Monitoring's `kubernetes.io/container/restart_count`
-- directly (see docs/DESIGN.md §5) — this is the BigQuery-only equivalent, derived
-- from `sink-k8s-events`, for reviewers who want the literal "query BigQuery for
-- restart counts" version.
SELECT
  resource.labels.namespace_name                                    AS namespace,
  resource.labels.pod_name                                          AS pod,
  jsonPayload.reason                                                 AS reason,
  COUNT(*)                                                           AS event_count
FROM `${PROJECT_ID}.logs_export.events`
WHERE
  resource.type = 'k8s_pod'
  AND jsonPayload.reason IN ('Killing', 'BackOff', 'Started')
  AND timestamp > TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 24 HOUR)
GROUP BY namespace, pod, reason
ORDER BY event_count DESC;

-- =============================================================================
-- 3. Request latency percentiles, p50/p95/p99 (BigQuery fallback for panel 3)
-- =============================================================================
-- Grafana's panel 3 queries Cloud Monitoring's
-- `loadbalancing.googleapis.com/https/total_latencies` directly. This is the
-- BigQuery-only equivalent, computed from exported LB request logs
-- (enable an LB log sink into `logs_export` alongside the two in
-- terraform/modules/observability if you want this table to populate —
-- see docs/IMPLEMENTATION.md Step 2 note).
SELECT
  TIMESTAMP_TRUNC(timestamp, MINUTE)                                          AS minute,
  APPROX_QUANTILES(CAST(httpRequest.latency AS FLOAT64), 100)[OFFSET(50)]     AS p50_seconds,
  APPROX_QUANTILES(CAST(httpRequest.latency AS FLOAT64), 100)[OFFSET(95)]     AS p95_seconds,
  APPROX_QUANTILES(CAST(httpRequest.latency AS FLOAT64), 100)[OFFSET(99)]     AS p99_seconds
FROM `${PROJECT_ID}.logs_export.requests`
WHERE
  resource.type = 'http_load_balancer'
  AND timestamp > TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 1 HOUR)
GROUP BY minute
ORDER BY minute DESC;

-- =============================================================================
-- 4. Raw log triage — single pod, recent log lines
-- =============================================================================
-- Useful during the live demo / troubleshooting: pull recent log lines for one pod.
-- NOTE: trace-ID correlation (filtering by `logging.googleapis.com/trace`) needs the
-- apps to actually inject a trace field, which they don't in this pass — Cloud Trace
-- is a documented fast-follow, not wired into the base apps (see docs/DESIGN.md §5,
-- docs/IMPLEMENTATION.md Step 9). Once added, swap the WHERE clause below for
-- `jsonPayload.\`logging.googleapis.com/trace\` = @trace_id`.
SELECT
  timestamp,
  resource.labels.pod_name                                           AS pod,
  jsonPayload.level                                                  AS level,
  jsonPayload.message                                                AS message
FROM `${PROJECT_ID}.logs_export.stdout`
WHERE
  resource.labels.pod_name = @pod_name -- bind via bq query --parameter
  AND timestamp > TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 1 HOUR)
ORDER BY timestamp ASC;

-- =============================================================================
-- 5. Resource utilization trend (BigQuery fallback for panel 4 — noisier proxy)
-- =============================================================================
-- CPU/memory are never logged, only measured — there is no log line equivalent.
-- Grafana's panel 4 queries Cloud Monitoring's
-- `kubernetes.io/container/cpu/core_usage_time` and `.../memory/used_bytes`
-- directly (see docs/DESIGN.md §5). As a rough, log-volume-based proxy only (NOT a
-- real utilization metric — included so a BigQuery-only path exists for every
-- panel, with the caveat made explicit):
SELECT
  TIMESTAMP_TRUNC(timestamp, MINUTE)                                 AS minute,
  resource.labels.container_name                                    AS app,
  COUNT(*)                                                           AS log_lines_per_minute
FROM `${PROJECT_ID}.logs_export.stdout`
WHERE
  resource.type = 'k8s_container'
  AND resource.labels.namespace_name = 'apps'
  AND timestamp > TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 1 HOUR)
GROUP BY minute, app
ORDER BY minute DESC;
