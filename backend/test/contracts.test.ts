import assert from "node:assert/strict";
import { test } from "node:test";
import { ConfigService } from "@nestjs/config";
import { ValidationPipe } from "@nestjs/common";
import { JwtService } from "@nestjs/jwt";
import { Types } from "mongoose";
import { PreferencesDto } from "../src/chat/dto";
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
test("independent logins issue distinct access JWTs even with the same user and issuance second", async (context) => {
  context.mock.timers.enable({ apis: ["Date"], now: Date.UTC(2026, 9, 16) });
  const user = {
    _id: new Types.ObjectId(),
    username: "debug_user_1",
    email: "debug1@example.test",
    displayName: "User 1",
    isDebugUser: true,
    debugUserNumber: 1,
    pts: 0,
  };
  const auth = new AuthService(
    { users: { findOne: () => ({ lean: async () => user }) } } as never,
    new JwtService(),
    new ConfigService({
      NODE_ENV: "development",
      JWT_SECRET: "synthetic-access-signing-secret",
      CENTRIFUGO_TOKEN_HMAC_SECRET_KEY: "synthetic-realtime-signing-secret",
    }),
  );
  const first = await auth.debugLogin(1);
  const second = await auth.debugLogin(1);
  assert.notEqual(first.accessToken, second.accessToken);
  const jwt = new JwtService();
  const firstClaims = jwt.decode(first.accessToken);
  const secondClaims = jwt.decode(second.accessToken);
  assert.equal(firstClaims.sub, secondClaims.sub);
  assert.equal(firstClaims.iat, secondClaims.iat);
  assert.match(firstClaims.jti, /^[a-f0-9-]{36}$/);
  assert.notEqual(firstClaims.jti, secondClaims.jti);
});
test("optional preference booleans accept omission but reject null and coerced values", async () => {
  const pipe = new ValidationPipe({ transform: true, whitelist: true });
  const validate = (value: unknown) =>
    pipe.transform(value, { type: "body", metatype: PreferencesDto });
  assert.equal((await validate({ pin: false })).pin, false);
  assert.equal((await validate({ isMuted: true })).isMuted, true);
  const omitted = await validate({});
  assert.equal(omitted.pin, undefined);
  assert.equal(omitted.isMuted, undefined);
  for (const field of ["pin", "isMuted"])
    for (const value of [null, 0, "false", [], {}])
      await assert.rejects(validate({ [field]: value }), { status: 400 });
});
test("OpenAPI describes every application route with protected membership APIs and schemas", () => {
  assert.equal(Object.keys(openApiDocument.paths).length, 26);
  assert.deepEqual(openApiDocument.paths["/messages"]!.post!.security, [
    { bearerAuth: [] },
  ]);
  assert.deepEqual(
    openApiDocument.paths["/auth/debug-login"]!.post!.security,
    [],
  );
  assert.ok(openApiDocument.components!.schemas!.InboxPublication);
  assert.ok(openApiDocument.paths["/uploads/image"]!.post!.requestBody);
  assert.deepEqual(openApiDocument.paths["/presence/offline"]!.post!.security, [
    { bearerAuth: [] },
  ]);
  assert.equal(
    openApiDocument.paths["/presence/offline"]!.post!.requestBody,
    undefined,
  );
  const schemas = openApiDocument.components!.schemas!;
  const hydrated = schemas.HydratedRoom as {
    properties: Record<string, unknown>;
    required: string[];
  };
  assert.ok(hydrated.properties.quoteUpdate);
  assert.ok(!hydrated.required.includes("quoteUpdate"));
  const messages = openApiDocument.paths["/rooms/{roomId}/messages"]!.get!
    .responses["200"] as unknown as {
    content: {
      "application/json": {
        schema: { properties: Record<string, unknown>; required: string[] };
      };
    };
  };
  assert.ok(messages.content["application/json"].schema.properties.receipts);
  assert.ok(
    !messages.content["application/json"].schema.required.includes("receipts"),
  );
});
