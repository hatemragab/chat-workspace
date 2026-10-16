import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";

// Synthetic, resumable fixtures for the real browser history/reply-jump check.
// Tokens stay in memory; no existing messages or databases are deleted.
const base = process.env.API_BASE_URL ?? "http://localhost:3000";
const title = process.env.HISTORY_GROUP_TITLE ?? "E2E history verification";
const fixturePath = fileURLToPath(
  new URL("../.runtime/history-fixture.json", import.meta.url),
);
const count = Number(process.env.HISTORY_MESSAGE_COUNT ?? 525);
assert.ok(Number.isInteger(count) && count >= 31 && count <= 1000);
const mode = process.argv[2] ?? "prepare";
assert.ok(["prepare", "fill"].includes(mode), "Use prepare or fill");

async function request(path, token, body) {
  const response = await fetch(`${base}${path}`, {
    method: body ? "POST" : "GET",
    headers: {
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
      ...(body ? { "Content-Type": "application/json" } : {}),
    },
    ...(body ? { body: JSON.stringify(body) } : {}),
    signal: AbortSignal.timeout(20000),
  });
  const data = await response.json();
  assert.ok(response.ok, `Fixture request ${path} failed (${response.status})`);
  return data;
}

await mkdir(new URL("../.runtime/", import.meta.url), {
  recursive: true,
  mode: 0o700,
});
const actor = await request("/auth/debug-login", null, {
  debugUserNumber: mode === "prepare" ? 1 : 2,
});
let fixture;
try {
  fixture = JSON.parse(await readFile(fixturePath, "utf8"));
} catch (error) {
  if (error.code !== "ENOENT") throw error;
}
const save = () =>
  writeFile(fixturePath, `${JSON.stringify(fixture, null, 2)}\n`, {
    mode: 0o600,
  });

if (mode === "prepare") {
  if (!fixture) {
    const page = await request("/rooms?limit=100", actor.accessToken);
    const room = page.rooms.find(
      (room) => room.displayTitle === title && room.roomType === "group",
    );
    assert.ok(room, "Create the named history group in the browser first");
    fixture = {
      roomId: room.roomId,
      title,
      count,
      seeded: 0,
      anchorKey: randomUUID(),
      replyKey: randomUUID(),
      keys: Array.from({ length: count }, () => randomUUID()),
    };
    await save();
  }
  if (!fixture.anchor) {
    const result = await request("/messages", actor.accessToken, {
      roomId: fixture.roomId,
      idempotencyKey: fixture.anchorKey,
      type: "text",
      text: "History anchor: jump back across 525 messages",
    });
    fixture.anchor = result.message;
    await save();
  }
  console.log(
    `Anchor ready in ${fixture.title}; open it in both browsers before disconnecting the first browser.`,
  );
} else {
  assert.ok(fixture?.anchor, "Run prepare first");
  for (let index = fixture.seeded; index < fixture.count; index++) {
    await request("/messages", actor.accessToken, {
      roomId: fixture.roomId,
      idempotencyKey: fixture.keys[index],
      type: "text",
      text: `History check ${String(index + 1).padStart(4, "0")} of ${fixture.count}`,
    });
    fixture.seeded = index + 1;
    await save();
    if (fixture.seeded % 50 === 0)
      console.log(
        `Seeded ${fixture.seeded}/${fixture.count} synthetic messages`,
      );
  }
  if (!fixture.reply) {
    const result = await request("/messages", actor.accessToken, {
      roomId: fixture.roomId,
      idempotencyKey: fixture.replyKey,
      type: "text",
      text: "A reply across 525 messages",
      replyToMessageId: fixture.anchor._id ?? fixture.anchor.id,
    });
    fixture.reply = result.message;
    await save();
  }
  console.log(
    "History fixture complete. Reopen the first browser and tap the latest quote to test remote context recovery.",
  );
}
