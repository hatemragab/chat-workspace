// An optional, narrow full-debug extension to inspector metadata. This is
// diagnostic data only: no supplied SQL is ever executed by the collector.
export const sqliteDetailLimit = 32 * 1024;
const operations = new Set([
  "select",
  "insert",
  "update",
  "delete",
  "custom",
  "batch",
]);
const tokens =
  /--[^\r\n]*|\/\*[\s\S]*?\*\/|'(?:''|[^'])*'|"(?:""|[^"])*"|`(?:``|[^`])*`|\[[^\]]*\]|\?[0-9]*|[:@$][a-zA-Z_][a-zA-Z_0-9]*|[a-zA-Z_][a-zA-Z_0-9]*|[0-9]+(?:\.[0-9]+)?|[\s\S]/g;
function secret(key) {
  const name = key.replace(/[^a-z0-9]/gi, "").toLowerCase();
  return (
    /password|passwd|pwd|token|authorization|cookie|apikey|accesskey|signingkey|clientkey|secret|credential|signature|privatekey|sessionid|appcheck|authenticate/.test(
      name,
    ) || /^(auth|authentication|bearer|jwt|pass|csrf)$/.test(name)
  );
}
function safeText(value) {
  return value
    .replace(/(\b[a-z][a-z0-9+.-]*:\/\/)[^/\s?#]+@/gi, "$1[REDACTED]@")
    .replace(/\b(?:Bearer|Basic)\s+[a-z0-9._~+/=-]+/gi, "[REDACTED]")
    .replace(/\beyJ[a-z0-9_-]+\.eyJ[a-z0-9_-]+\.[a-z0-9_-]+\b/gi, "[REDACTED]")
    .replace(/([?&])([^=&#]+)=([^&#]*)/g, (original, prefix, key) => {
      try {
        return secret(decodeURIComponent(key))
          ? `${prefix}${key}=[REDACTED]`
          : original;
      } catch {
        return original;
      }
    });
}
function omitted(reason, extra = {}) {
  return { payloadOmitted: true, omissionReason: reason, ...extra };
}
function snapshot(value, depth = 0, budget = { entries: 4096 }) {
  if (depth > 16 || --budget.entries < 0)
    return omitted("detail_depth_or_entry_limit");
  if (
    value == null ||
    typeof value === "boolean" ||
    (typeof value === "number" && Number.isFinite(value))
  )
    return value;
  if (typeof value === "string") {
    if (Buffer.byteLength(value) > 8192) return omitted("value_byte_limit");
    if (/^\s*[\[{"]/.test(value)) {
      try {
        return JSON.stringify(snapshot(JSON.parse(value), depth + 1, budget));
      } catch {
        /* Ordinary SQLite text. */
      }
    }
    return safeText(value);
  }
  if (Array.isArray(value))
    return [
      ...value.slice(0, 512).map((item) => snapshot(item, depth + 1, budget)),
      ...(value.length > 512
        ? [omitted("array_entry_limit", { omittedEntries: value.length - 512 })]
        : []),
    ];
  if (value && typeof value === "object") {
    const entries = Object.entries(value);
    return Object.fromEntries([
      ...entries
        .slice(0, 256)
        .map(([key, item]) => [
          key,
          secret(key)
            ? "[REDACTED]"
            : key === "upload_bytes" && Array.isArray(item)
              ? { type: "binary", length: item.length }
              : snapshot(item, depth + 1, budget),
        ]),
      ...(entries.length > 256
        ? [
            [
              "__omitted__",
              omitted("object_entry_limit", {
                omittedEntries: entries.length - 256,
              }),
            ],
          ]
        : []),
    ]);
  }
  return omitted("unsupported_value");
}
// Shared credential redaction and defensive bounds for local debug payloads.
export { snapshot as debugPayloadSnapshot };
function sql(value) {
  if (typeof value !== "string" || Buffer.byteLength(value) > 8192)
    return { statement: omitted("statement_byte_limit"), sensitive: true };
  const parts = value.match(tokens) ?? [];
  const literal = (token) => token.startsWith("'");
  const comment = (token) => token.startsWith("--") || token.startsWith("/*");
  const sensitive = parts.some(
    (token) => !literal(token) && !comment(token) && secret(token),
  );
  let previous;
  let statement = "";
  for (const token of parts) {
    if (comment(token)) statement += "/* comment omitted */";
    else if (literal(token)) {
      if (token.length < 2)
        return { statement: omitted("invalid_literal"), sensitive: true };
      const text = token.slice(1, -1).replaceAll("''", "'");
      const safe = sensitive
        ? "[REDACTED]"
        : previous?.toUpperCase() === "X"
          ? "[BINARY]"
          : snapshot(text);
      statement += `'${String(safe).replaceAll("'", "''")}'`;
    } else
      statement += sensitive && /^[0-9]/.test(token) ? "[REDACTED]" : token;
    if (token.trim() && !comment(token)) previous = token;
  }
  return { statement, sensitive };
}
function parameters(value, sensitive) {
  if (!Array.isArray(value)) return [];
  return value.slice(0, 256).flatMap((item) =>
    !item || !Number.isSafeInteger(item.position) || item.position < 1
      ? []
      : [
          {
            position: item.position,
            storageType: [
              "null",
              "integer",
              "real",
              "boolean",
              "text",
              "blob",
              "other",
            ].includes(item.storageType)
              ? item.storageType
              : "other",
            value: sensitive
              ? "[REDACTED]"
              : item.storageType === "blob"
                ? snapshot(
                    item.value?.type === "binary"
                      ? item.value
                      : {
                          type: "binary",
                          length: Array.isArray(item.value)
                            ? item.value.length
                            : null,
                        },
                  )
                : snapshot(item.value),
          },
        ],
  );
}
const count = (value) =>
  Number.isSafeInteger(value) && value >= 0 ? value : 0;

export function sqliteLogDetails(value, operation) {
  if (
    !value ||
    typeof value !== "object" ||
    value.policy !== "full_debug" ||
    value.database !== "chat_app_db" ||
    !operations.has(operation)
  )
    return undefined;
  const common = { policy: "full_debug", database: "chat_app_db", operation };
  if (value.payloadOmitted === true)
    return { ...common, ...omitted("producer_omission") };
  if (value.operation !== operation)
    return { ...common, ...omitted("invalid_operation") };
  let result;
  let sensitive = false;
  if (operation === "batch") {
    const templates = Array.isArray(value.statements)
      ? value.statements.slice(0, 128).map((item) => ({
          statementIndex: count(item?.statementIndex),
          ...sql(item?.statement),
        }))
      : [];
    sensitive = templates.some((item) => item.sensitive);
    result = {
      ...common,
      statements: templates.map(({ statementIndex, statement }) => ({
        statementIndex,
        statement,
      })),
      statementsOmitted:
        count(value.statementsOmitted) +
        Math.max(0, (value.statements?.length ?? 0) - templates.length),
      executions: Array.isArray(value.executions)
        ? value.executions.slice(0, 256).map((item) => ({
            statementIndex: count(item?.statementIndex),
            parameters: parameters(
              item?.parameters,
              templates.find(
                (template) => template.statementIndex === item?.statementIndex,
              )?.sensitive !== false,
            ),
            parametersOmitted: count(item?.parametersOmitted),
          }))
        : [],
      executionsOmitted:
        count(value.executionsOmitted) +
        Math.max(0, (value.executions?.length ?? 0) - 256),
    };
  } else {
    const parsed = sql(value.statement);
    sensitive = parsed.sensitive || value.credentialsOmitted === true;
    const bindings = parameters(value.parameters, sensitive);
    result = {
      ...common,
      statement: parsed.statement,
      parameters: bindings,
      parametersOmitted:
        count(value.parametersOmitted) +
        Math.max(0, (value.parameters?.length ?? 0) - bindings.length),
      ...(sensitive ? { credentialsOmitted: true } : {}),
    };
  }
  if (
    value.result &&
    typeof value.result === "object" &&
    !Array.isArray(value.result)
  ) {
    result.result = snapshot(
      Object.fromEntries(
        Object.entries(value.result).filter(([key]) =>
          [
            "rowCount",
            "rows",
            "rowsCaptured",
            "rowsOmitted",
            "lastInsertRowId",
            "affectedRows",
            "outcome",
            "observation",
            "credentialsOmitted",
          ].includes(key),
        ),
      ),
    );
    if (Array.isArray(value.result.rows) && value.result.rows.length > 512) {
      result.result.rowsCaptured = 512;
      result.result.rowsOmitted =
        count(value.result.rowsOmitted) + value.result.rows.length - 512;
    }
    if (sensitive && "rows" in value.result)
      result.result = {
        ...result.result,
        rows: [],
        rowsCaptured: 0,
        rowsOmitted: count(value.result.rowCount),
        credentialsOmitted: true,
      };
  }
  const bytes = Buffer.byteLength(JSON.stringify(result));
  return bytes > sqliteDetailLimit
    ? {
        ...common,
        ...omitted("detail_byte_limit", {
          omittedBytes: bytes,
          limitBytes: sqliteDetailLimit,
        }),
      }
    : result;
}
