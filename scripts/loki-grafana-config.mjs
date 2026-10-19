import { join, resolve } from "node:path";

export const GRAFANA_URL = "http://127.0.0.1:3001";
export const LOKI_URL = "http://127.0.0.1:3100";
export const ALLOY_URL = "http://127.0.0.1:12345";
export const DASHBOARD_PATH = "/d/chat-logs/chat-workspace-logs";

export function comparisonPaths(root) {
  const directory = resolve(root, ".runtime/loki-grafana");
  return {
    directory,
    capture: resolve(root, ".runtime/observability/events.jsonl"),
    archives: resolve(root, ".runtime/observability/archives/events.*.jsonl"),
    state: join(directory, "supervisor.json"),
    password: join(directory, "admin-password"),
    secret: join(directory, "secret-key"),
  };
}

/** No host credentials or application environment are needed by this stack. */
export function comparisonConfiguration(root, configurationDirectory) {
  const p = comparisonPaths(root);
  const config = configurationDirectory ?? join(p.directory, "config/current");
  const q = JSON.stringify;
  return {
    "loki.json":
      JSON.stringify(
        {
          auth_enabled: false,
          server: {
            http_listen_address: "127.0.0.1",
            http_listen_port: 3100,
            grpc_listen_address: "127.0.0.1",
            grpc_listen_port: 9096,
            log_level: "warn",
          },
          common: {
            instance_addr: "127.0.0.1",
            path_prefix: join(p.directory, "loki"),
            storage: {
              filesystem: {
                chunks_directory: join(p.directory, "loki/chunks"),
                rules_directory: join(p.directory, "loki/rules"),
              },
            },
            replication_factor: 1,
            ring: { kvstore: { store: "inmemory" } },
          },
          schema_config: {
            configs: [
              {
                from: "2020-01-01",
                store: "tsdb",
                object_store: "filesystem",
                schema: "v13",
                index: { prefix: "index_", period: "24h" },
              },
            ],
          },
          // Archives and the live file can arrive concurrently during first import.
          ingester: { max_chunk_age: "336h", wal: { enabled: true } },
          limits_config: {
            allow_structured_metadata: true,
            reject_old_samples: false,
            ingestion_rate_mb: 16,
            ingestion_burst_size_mb: 32,
            per_stream_rate_limit: "16MB",
            per_stream_rate_limit_burst: "32MB",
            max_line_size: "1MB",
            max_line_size_truncate: false,
            max_entries_limit_per_query: 10000,
          },
          // This trial never expires captured data automatically.
          compactor: { retention_enabled: false },
          analytics: { reporting_enabled: false },
        },
        null,
        2,
      ) + "\n",
    "config.alloy": `logging {
  level = "warn"
}
loki.source.file "vector_capture" {
  targets = [
    {__path__ = ${q(p.capture)}, job = "chat-workspace"},
    {__path__ = ${q(p.archives)}, job = "chat-workspace"},
  ]
  tail_from_end = false
  file_match {
    enabled = true
    sync_period = "1s"
  }
  forward_to = [loki.process.vector_capture.receiver]
}
loki.process "vector_capture" {
  stage.json {
    expressions = {
      timestamp = "timestamp",
      source = "source",
      level = "level",
      origin = "origin",
      request_id = "requestId",
      trace_id = "traceId",
      span_id = "spanId",
      test_run_id = "test_run_id",
    }
  }
  stage.timestamp {
    source = "timestamp"
    format = "RFC3339Nano"
    action_on_failure = "skip"
  }
  stage.labels {
    values = { source = "", level = "", origin = "" }
  }
  stage.structured_metadata {
    values = { request_id = "", trace_id = "", span_id = "", test_run_id = "" }
  }
  stage.label_drop {
    values = ["filename"]
  }
  forward_to = [loki.write.local.receiver]
}
loki.write "local" {
  endpoint {
    url = "${LOKI_URL}/loki/api/v1/push"
    follow_redirects = false
    batch_wait = "250ms"
    max_backoff_period = "5s"
    max_backoff_retries = 0
  }
}
`,
    "grafana.ini": `[paths]
data = ${join(p.directory, "grafana")}
logs = ${join(p.directory, "grafana-logs")}
plugins = ${join(p.directory, "plugins")}
provisioning = ${join(config, "provisioning")}
[server]
http_addr = 127.0.0.1
http_port = 3001
domain = 127.0.0.1
root_url = ${GRAFANA_URL}/
[security]
admin_password = $__file{${p.password}}
secret_key = $__file{${p.secret}}
cookie_samesite = strict
[auth]
disable_login_form = true
[auth.anonymous]
enabled = true
org_name = Main Org.
org_role = Viewer
[users]
allow_sign_up = false
[analytics]
reporting_enabled = false
check_for_updates = false
check_for_plugin_updates = false
[news]
news_feed_enabled = false
[plugins]
preinstall_disabled = true
[log]
mode = console
level = warn
[date_formats]
default_timezone = Africa/Cairo
full_date = DD HH:mm:ss
`,
    "provisioning/datasources/loki.yaml": `apiVersion: 1
datasources:
  - name: Chat Loki
    uid: chat-loki
    type: loki
    access: proxy
    url: ${LOKI_URL}
    isDefault: true
    editable: false
    jsonData:
      maxLines: 1000
      timeout: 60
`,
    "provisioning/dashboards/chat.yaml": `apiVersion: 1
providers:
  - name: Chat logs comparison
    orgId: 1
    folder: Chat workspace
    type: file
    disableDeletion: true
    allowUiUpdates: false
    updateIntervalSeconds: 30
    options:
      path: ${join(config, "dashboards")}
`,
    "dashboards/chat-logs.json":
      JSON.stringify(comparisonDashboard(), null, 2) + "\n",
  };
}

export function comparisonDashboard() {
  const datasource = { type: "loki", uid: "chat-loki" };
  const selector = '{job="chat-workspace",source=~"$source",level=~"$level"}';
  const logs = selector + " |~ ${search:doublequote}";
  const panel = (id, title, type, expr, x, y, w, h, options = {}) => ({
    id,
    title,
    type,
    datasource,
    gridPos: { x, y, w, h },
    targets: [{ refId: "A", datasource, expr, queryType: "range" }],
    options,
    ...(type === "stat"
      ? {
          fieldConfig: {
            defaults: {
              color: { mode: "fixed", fixedColor: "orange" },
              displayName: "${__field.labels.level}",
            },
            overrides: [
              {
                matcher: { id: "byName", options: "error" },
                properties: [
                  { id: "color", value: { mode: "fixed", fixedColor: "red" } },
                ],
              },
            ],
          },
        }
      : {}),
  });
  return {
    uid: "chat-logs",
    title: "Chat workspace logs",
    schemaVersion: 39,
    tags: ["chat", "logs", "comparison"],
    editable: false,
    timezone: "Africa/Cairo",
    refresh: "5s",
    time: { from: "now-12h", to: "now" },
    links: [
      {
        title: "Compare in Logdy",
        url: "http://127.0.0.1:8082/",
        targetBlank: true,
      },
      {
        title: "Explore LogQL",
        url: `${GRAFANA_URL}/explore`,
        targetBlank: true,
      },
    ],
    templating: {
      list: [
        ...["source", "level"].map((name) => ({
          name,
          label: name === "source" ? "Source" : "Level",
          type: "query",
          datasource,
          query: `label_values({job="chat-workspace"}, ${name})`,
          refresh: 1,
          multi: true,
          includeAll: true,
          allValue: ".+",
          current: { text: "All", value: "$__all" },
        })),
        {
          name: "search",
          label: "Search regex / request ID",
          type: "textbox",
          query: "",
          current: { text: "", value: "" },
        },
      ],
    },
    panels: [
      panel(
        1,
        "Logs per second by source",
        "timeseries",
        `sum by (source) (rate(${selector}[$__auto]))`,
        0,
        0,
        16,
        7,
        { legend: { displayMode: "table", placement: "bottom" } },
      ),
      panel(
        2,
        "Warnings and errors in selected range",
        "stat",
        'sum by (level) (count_over_time({job="chat-workspace",source=~"$source",level=~"warn|error"}[$__range]))',
        16,
        0,
        8,
        7,
        { reduceOptions: { calcs: ["lastNotNull"] } },
      ),
      panel(
        3,
        "Same Vector capture as Logdy — expand a row for JSON",
        "logs",
        logs,
        0,
        7,
        24,
        18,
        {
          showTime: true,
          showLabels: true,
          wrapLogMessage: false,
          prettifyLogMessage: true,
          enableLogDetails: true,
          sortOrder: "Descending",
          dedupStrategy: "none",
        },
      ),
    ],
  };
}
