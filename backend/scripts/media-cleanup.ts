import { existsSync, readFileSync, constants } from "node:fs";
import { lstat, open, readdir, unlink } from "node:fs/promises";
import { join } from "node:path";
import { parseEnv } from "node:util";
import mongoose from "mongoose";
import {
  MessageSchema,
  RoomSchema,
  UploadSchema,
  UserSchema,
} from "../src/models";
import { uploadFilenamePattern } from "../src/chat/uploads.service";

// This command never starts Nest, seeds users, connects Redis, or changes a service.
async function main() {
  const apply = process.argv.includes("--apply");
  if (
    process.argv
      .slice(2)
      .some(
        (arg) => !["--apply", "--confirm-retained-media-cleanup"].includes(arg),
      )
  )
    throw new Error("Unknown cleanup argument");
  if (apply && !process.argv.includes("--confirm-retained-media-cleanup"))
    throw new Error("Apply requires --confirm-retained-media-cleanup");
  for (const file of [".env", "../centrifugo/.env"])
    if (existsSync(file))
      Object.entries(parseEnv(readFileSync(file, "utf8"))).forEach(
        ([key, value]) => {
          if (process.env[key] === undefined) process.env[key] = value;
        },
      );
  if (!process.env.MONGODB_URI) throw new Error("MONGODB_URI is required");
  await mongoose.connect(process.env.MONGODB_URI, {
    autoIndex: false,
    autoCreate: false,
    serverSelectionTimeoutMS: 5000,
  });
  const uploads = mongoose.model("CleanupUpload", UploadSchema);
  const messages = mongoose.model("CleanupMessage", MessageSchema);
  const rooms = mongoose.model("CleanupRoom", RoomSchema);
  const users = mongoose.model("CleanupUser", UserSchema);
  const root = join(process.cwd(), "public/uploads");
  const info = await lstat(root);
  if (!info.isDirectory() || info.isSymbolicLink())
    throw new Error("Unsafe media directory");
  const summary = {
    mode: apply ? "apply" : "dry-run",
    retainedFiles: 0,
    legacyOrUnknownFiles: 0,
    orphanCandidates: 0,
    removed: 0,
    skipped: 0,
  };
  for (const filename of await readdir(root)) {
    if (!uploadFilenamePattern.test(filename)) continue;
    summary.retainedFiles++;
    const metadata = await uploads.findOne({ filename }).lean();
    if (!metadata) {
      summary.legacyOrUnknownFiles++;
      continue;
    }
    // Attached media is retained indefinitely. Only expired, never-attached NEW uploads qualify.
    if (
      metadata.state !== "retained" ||
      metadata.attachedAt ||
      metadata.orphanEligibleAt > new Date()
    )
      continue;
    const imageUrl = `/public/uploads/${filename}`;
    const referenced = async () =>
      !!(await messages.exists({
        $or: [{ imageUrl }, { "replyTo.imageUrl": imageUrl }],
      })) ||
      !!(await rooms.exists({ avatarUrl: imageUrl })) ||
      !!(await users.exists({ avatarUrl: imageUrl }));
    if (await referenced()) {
      summary.skipped++;
      continue;
    }
    const fileInfo = await lstat(join(root, filename));
    if (
      !fileInfo.isFile() ||
      fileInfo.isSymbolicLink() ||
      fileInfo.nlink !== 1
    ) {
      summary.skipped++;
      continue;
    }
    summary.orphanCandidates++;
    if (!apply) continue;
    const claimed = await uploads.findOneAndUpdate(
      {
        _id: metadata._id,
        attachedAt: null,
        state: "retained",
        orphanEligibleAt: { $lte: new Date() },
      },
      { $set: { state: "deleting" } },
      { new: true },
    );
    if (!claimed) {
      summary.skipped++;
      continue;
    }
    try {
      if (await referenced()) {
        await uploads.updateOne(
          { _id: metadata._id },
          { $set: { state: "retained" } },
        );
        summary.skipped++;
        continue;
      }
      const handle = await open(
        join(root, filename),
        constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK,
      );
      const current = await handle.stat();
      await handle.close();
      const fresh = await lstat(join(root, filename));
      if (
        !fresh.isFile() ||
        fresh.nlink !== 1 ||
        current.ino !== fileInfo.ino ||
        fresh.ino !== current.ino ||
        current.dev !== fileInfo.dev
      )
        throw new Error("Media changed during cleanup");
      await unlink(join(root, filename));
      await uploads.updateOne(
        { _id: metadata._id },
        { $set: { state: "deleted", deletedAt: new Date() } },
      );
      summary.removed++;
    } catch {
      // Preserve bytes/metadata wherever possible; never report raw paths or credentials.
      await uploads.updateOne(
        { _id: metadata._id, state: "deleting" },
        { $set: { state: "retained" } },
      );
      summary.skipped++;
    }
  }
  process.stdout.write(JSON.stringify(summary) + "\n");
}
void main()
  .catch(() => {
    process.stderr.write(
      "Media inventory failed; verify local configuration, database and directory permissions.\n",
    );
    process.exitCode = 1;
  })
  .finally(() => mongoose.disconnect());
