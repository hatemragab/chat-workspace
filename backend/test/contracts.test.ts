import assert from "node:assert/strict";
import { test } from "node:test";
import { ConfigService } from "@nestjs/config";
import { AuthService } from "../src/auth/auth.service";
import { directPairKey, cursorBefore } from "../src/chat/chat.service";
import { hasImageSignature } from "../src/chat/uploads.controller";
import {
  MessageSchema,
  RoomSchema,
  RoomMemberSchema,
  UserSchema,
} from "../src/models";
import { openApiDocument } from "../src/openapi";

test("direct pair keys are stable in either participant order", () => {
  assert.equal(directPairKey("bbbb", "aaaa"), "aaaa_bbbb");
  assert.equal(directPairKey("aaaa", "bbbb"), "aaaa_bbbb");
});
test("compound cursor preserves equal timestamp ObjectId boundary", () => {
  const cursor = cursorBefore(
    "createdAt",
    "_id",
    "2026-01-01T00:00:00Z",
    "507f1f77bcf86cd799439011",
  );
  assert.deepEqual(cursor.$or[0], {
    createdAt: { $lt: new Date("2026-01-01T00:00:00Z") },
  });
  assert.equal(
    String((cursor.$or[1] as { _id: { $lt: unknown } })._id.$lt),
    "507f1f77bcf86cd799439011",
  );
});
test("image signature rejects MIME spoofing and unsupported SVG", () => {
  assert.equal(
    hasImageSignature(
      Buffer.from("<svg><script>alert(1)</script></svg>"),
      "image/png",
    ),
    false,
  );
  assert.equal(
    hasImageSignature(Buffer.from("<svg/>"), "image/svg+xml"),
    false,
  );
  assert.equal(
    hasImageSignature(Buffer.from([255, 216, 255, 224]), "image/jpeg"),
    true,
  );
  assert.equal(
    hasImageSignature(Buffer.from("GIF89a12345678"), "image/gif"),
    true,
  );
  assert.equal(
    hasImageSignature(Buffer.from("RIFF1234WEBP1234"), "image/webp"),
    true,
  );
});
test("schemas keep sender-scoped idempotency and direct-only partial index", () => {
  const direct = RoomSchema.indexes().find(
    ([keys]) => "directPairKey" in keys,
  )!;
  assert.equal(direct[1].unique, true);
  assert.deepEqual(direct[1].partialFilterExpression, {
    type: "direct",
    directPairKey: { $type: "string" },
  });
  assert.equal(RoomSchema.path("directPairKey").options.default, undefined);
  assert.ok(
    MessageSchema.indexes().some(
      ([keys, options]) =>
        keys.senderId === 1 && keys.idempotencyKey === 1 && options.unique,
    ),
  );
  assert.ok(
    RoomMemberSchema.indexes().some(
      ([keys, options]) =>
        keys.roomId === 1 && keys.userId === 1 && options.unique,
    ),
  );
  assert.equal(UserSchema.path("passwordHash").options.select, false);
});
test("debug login and listing are absent outside development", async () => {
  const auth = new AuthService(
    {} as never,
    {} as never,
    new ConfigService({ NODE_ENV: "production" }),
  );
  assert.throws(() => auth.requireDebug(), { status: 404 });
  await assert.rejects(auth.debugLogin(1), { status: 404 });
});
test("OpenAPI describes every application route with protected membership APIs and schemas", () => {
  assert.equal(Object.keys(openApiDocument.paths).length, 24);
  assert.deepEqual(openApiDocument.paths["/messages"]!.post!.security, [
    { bearerAuth: [] },
  ]);
  assert.deepEqual(
    openApiDocument.paths["/auth/debug-login"]!.post!.security,
    [],
  );
  assert.ok(openApiDocument.components!.schemas!.InboxPublication);
  assert.ok(openApiDocument.paths["/uploads/image"]!.post!.requestBody);
});
