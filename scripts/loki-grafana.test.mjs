import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import {
  mkdtemp,
  readFile,
  realpath,
  stat,
  symlink,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import {
  comparisonConfiguration,
  comparisonDashboard,
} from "./loki-grafana-config.mjs";
import { writePrivateConfiguration } from "./loki-grafana.mjs";

test("private generated files are repeatable and preserve existing different content", async () => {
  const root = await mkdtemp(
    join(await realpath(tmpdir()), "chat-loki-config-"),
  );
  const file = join(root, "nested/config.json");
  await writePrivateConfiguration(file, "original\n");
  await writePrivateConfiguration(file, "original\n");
  await assert.rejects(
    writePrivateConfiguration(file, "replacement\n"),
    /preserved/,
  );
  assert.equal(await readFile(file, "utf8"), "original\n");
  assert.equal((await stat(file)).mode & 0o777, 0o600);
  assert.equal((await stat(join(root, "nested"))).mode & 0o777, 0o700);
});

test("generated configuration rejects linked files and linked directories", async () => {
  const root = await mkdtemp(
    join(await realpath(tmpdir()), "chat-loki-links-"),
  );
  const target = join(root, "target");
  await writeFile(target, "private original");
  await symlink(target, join(root, "linked"));
  await assert.rejects(writePrivateConfiguration(join(root, "linked"), "new"));
  await symlink(root, join(root, "linked-directory"));
  await assert.rejects(
    writePrivateConfiguration(join(root, "linked-directory/new"), "new"),
  );
  assert.equal(await readFile(target, "utf8"), "private original");
});

test("native configs compile and support the existing one-MiB capture ceiling", async () => {
  const root = await mkdtemp(
    join(await realpath(tmpdir()), "chat-loki-native-"),
  );
  const configs = comparisonConfiguration(root);
  const loki = JSON.parse(configs["loki.json"]);
  assert.equal(loki.server.http_listen_address, "127.0.0.1");
  assert.equal(loki.server.grpc_listen_address, "127.0.0.1");
  assert.equal(loki.limits_config.max_line_size, "1MB");
  assert.equal(loki.limits_config.max_line_size_truncate, false);
  assert.equal(loki.compactor.retention_enabled, false);
  assert.equal(loki.analytics.reporting_enabled, false);
  assert.match(configs["config.alloy"], /archives\/events\.\*\.jsonl/);
  assert.match(configs["config.alloy"], /tail_from_end = false/);
  assert.doesNotMatch(configs["config.alloy"], /stage\.output/);
  const labelStage = configs["config.alloy"].match(
    /stage\.labels \{([\s\S]*?)\n  \}/,
  )[1];
  assert.doesNotMatch(
    labelStage,
    /request|trace|span|user|room|test_run|capture|instance/,
  );
  for (const name of ["loki.json", "config.alloy"])
    await writePrivateConfiguration(join(root, name), configs[name]);
  const exec = promisify(execFile);
  const { stdout } = await exec("brew", ["--prefix"]);
  const prefix = stdout.trim();
  await exec(join(prefix, "opt/loki/bin/loki"), [
    `-config.file=${join(root, "loki.json")}`,
    "-verify-config=true",
  ]);
  await exec(join(prefix, "opt/grafana-alloy/bin/alloy"), [
    "validate",
    join(root, "config.alloy"),
  ]);
});

test("dashboard keeps regex input quoted and raw JSON details available", () => {
  const dashboard = comparisonDashboard();
  const logs = dashboard.panels.find((p) => p.type === "logs");
  assert.match(logs.targets[0].expr, /\$\{search:doublequote\}/);
  assert.equal(logs.options.enableLogDetails, true);
  assert.equal(logs.options.dedupStrategy, "none");
  assert.equal(dashboard.timezone, "Africa/Cairo");
  assert.equal(dashboard.links[0].url, "http://127.0.0.1:8082/");
});
