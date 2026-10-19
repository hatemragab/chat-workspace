import { createHash } from "node:crypto";

// Only call after bearer validation. No raw access credentials enter Redis.
export const sessionHash = (authorization: string) =>
  createHash("sha256").update(authorization.slice(7)).digest("hex");
