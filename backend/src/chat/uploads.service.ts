import {
  BadRequestException,
  Injectable,
  NotFoundException,
} from "@nestjs/common";
import { ConfigService } from "@nestjs/config";
import { ClientSession, Types } from "mongoose";
import sharp from "sharp";
import { constants } from "node:fs";
import { lstat, mkdir, open, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { randomUUID } from "node:crypto";
import { DatabaseService } from "../infrastructure/database.service";
import { BoundedWork, boundedSetting } from "../infrastructure/bounded-work";

export const imageExtensions: Readonly<Record<string, string>> = {
  "image/jpeg": ".jpg",
  "image/png": ".png",
  "image/webp": ".webp",
  "image/gif": ".gif",
};
export function hasImageSignature(buffer: Buffer, mime: string): boolean {
  if (mime === "image/jpeg")
    return (
      buffer.length >= 4 &&
      buffer.subarray(0, 3).equals(Buffer.from([255, 216, 255]))
    );
  if (mime === "image/png")
    return (
      buffer.length >= 24 &&
      buffer
        .subarray(0, 8)
        .equals(Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]))
    );
  if (mime === "image/gif")
    return (
      buffer.length >= 13 &&
      /^GIF8[79]a$/.test(buffer.subarray(0, 6).toString("ascii"))
    );
  if (mime === "image/webp")
    return (
      buffer.length >= 16 &&
      buffer.subarray(0, 4).toString("ascii") === "RIFF" &&
      buffer.subarray(8, 12).toString("ascii") === "WEBP"
    );
  return false;
}
export const uploadFilenamePattern =
  /^[a-zA-Z0-9][a-zA-Z0-9_-]{0,199}\.(jpg|jpeg|png|webp|gif)$/i;

@Injectable()
export class UploadsService {
  private readonly decoding: BoundedWork;
  constructor(
    private readonly db: DatabaseService,
    private readonly config: ConfigService,
  ) {
    this.decoding = new BoundedWork(
      boundedSetting(config, "UPLOAD_MAX_CONCURRENT", 4, 64),
      0,
    );
  }
  private root() {
    return join(process.cwd(), "public/uploads");
  }
  private filename(path: string) {
    const filename = path.replace(/^\/public\/uploads\//, "");
    if (
      !path.startsWith("/public/uploads/") ||
      !uploadFilenamePattern.test(filename)
    )
      throw new BadRequestException("Image must be a server upload path");
    return filename;
  }
  async store(userId: string, file?: Express.Multer.File) {
    return this.decoding.run(() => this.storeDecoded(userId, file));
  }
  private async storeDecoded(userId: string, file?: Express.Multer.File) {
    if (!file || !hasImageSignature(file.buffer, file.mimetype))
      throw new BadRequestException("A valid image file is required");
    const maxPixels = boundedSetting(
      this.config,
      "UPLOAD_MAX_PIXELS",
      16000000,
      64000000,
    );
    const maxDimension = boundedSetting(
      this.config,
      "UPLOAD_MAX_DIMENSION",
      8192,
      32768,
    );
    const maxFrames = boundedSetting(
      this.config,
      "UPLOAD_MAX_FRAMES",
      60,
      1000,
    );
    let width: number, height: number, frames: number;
    try {
      const image = sharp(file.buffer, {
        animated: true,
        limitInputPixels: maxPixels,
        failOn: "warning",
      });
      const metadata = await image.metadata();
      width = metadata.width ?? 0;
      height = metadata.pageHeight ?? metadata.height ?? 0;
      frames = metadata.pages ?? 1;
      const expected =
        file.mimetype === "image/jpeg" ? "jpeg" : file.mimetype.slice(6);
      if (
        metadata.format !== expected ||
        width < 1 ||
        height < 1 ||
        width > maxDimension ||
        height > maxDimension ||
        frames > maxFrames ||
        width * height * frames > maxPixels
      )
        throw new Error("Image budget exceeded");
      // Decode every retained frame; a matching header alone cannot pass.
      await image.raw().toBuffer();
    } catch {
      throw new BadRequestException(
        "Image cannot be decoded or exceeds dimension/frame/pixel limits",
      );
    }
    const filename = `${randomUUID()}${imageExtensions[file.mimetype]}`;
    await mkdir(this.root(), { recursive: true, mode: 0o700 });
    const root = await lstat(this.root());
    if (!root.isDirectory() || root.isSymbolicLink())
      throw new Error("Unsafe upload directory");
    await writeFile(join(this.root(), filename), file.buffer, {
      flag: "wx",
      mode: 0o600,
    });
    // Ambiguous metadata failures retain bytes for explicit dry-run inventory.
    await this.db.uploads.create({
      filename,
      ownerId: new Types.ObjectId(userId),
      mime: file.mimetype,
      bytes: file.size,
      width,
      height,
      frames,
      orphanEligibleAt: new Date(
        Date.now() +
          boundedSetting(this.config, "UPLOAD_ORPHAN_RETENTION_DAYS", 7, 3650) *
            86400000,
      ),
    });
    return { imageUrl: `/public/uploads/${filename}` };
  }
  async canRead(
    userId: string,
    path: string,
    session?: ClientSession,
  ): Promise<boolean> {
    const filename = this.filename(path);
    const owner = new Types.ObjectId(userId);
    const upload = await this.db.uploads
      .findOne({ filename })
      .session(session ?? null)
      .lean();
    if (upload && upload.state !== "retained") return false;
    if (upload && !upload.attachedAt && upload.ownerId.equals(owner))
      return true;
    const visible = await this.db.messages
      .aggregate([
        {
          $match: {
            isDeletedForAll: false,
            deletedForUsers: { $nin: [owner] },
            $or: [
              { imageUrl: { $eq: path, $type: "string" } },
              {
                "replyTo.imageUrl": { $eq: path, $type: "string" },
                "replyTo.isDeleted": false,
              },
            ],
          },
        },
        {
          $lookup: {
            from: "room_members",
            let: { room: "$roomId" },
            pipeline: [
              {
                $match: {
                  $expr: {
                    $and: [
                      { $eq: ["$roomId", "$$room"] },
                      { $eq: ["$userId", owner] },
                    ],
                  },
                },
              },
            ],
            as: "access",
          },
        },
        {
          $match: {
            "access.0": { $exists: true },
            $expr: {
              $gt: [
                "$createdAt",
                {
                  $ifNull: [
                    { $arrayElemAt: ["$access.clearedAt", 0] },
                    new Date(0),
                  ],
                },
              ],
            },
          },
        },
        { $limit: 1 },
        { $project: { _id: 1 } },
      ])
      .session(session ?? null);
    if (visible.length) return true;
    const group = await this.db.rooms
      .findOne({ avatarUrl: path, participantIds: owner })
      .select("_id")
      .session(session ?? null)
      .lean();
    if (
      group &&
      (await this.db.members
        .exists({ roomId: group._id, userId: owner })
        .session(session ?? null))
    )
      return true;
    const profile = await this.db.users
      .findOne({ avatarUrl: path })
      .select("_id")
      .session(session ?? null)
      .lean();
    if (!profile) return false;
    if (profile._id.equals(owner)) return true;
    const shared = await this.db.rooms
      .findOne({ participantIds: { $all: [owner, profile._id] } })
      .select("_id")
      .session(session ?? null)
      .lean();
    return (
      !!shared &&
      !!(await this.db.members
        .exists({ roomId: shared._id, userId: owner })
        .session(session ?? null))
    );
  }
  async attach(
    userId: string,
    path: string | undefined,
    session: ClientSession,
  ) {
    if (path === undefined) return;
    const filename = this.filename(path);
    if (!(await this.canRead(userId, path, session)))
      throw new NotFoundException("Image not available");
    const attached = await this.db.uploads.updateOne(
      { filename, state: "retained" },
      [{ $set: { attachedAt: { $ifNull: ["$attachedAt", new Date()] } } }],
      { session },
    );
    if (
      !attached.matchedCount &&
      (await this.db.uploads.exists({ filename }).session(session))
    )
      throw new NotFoundException("Image not available");
  }
  async read(userId: string, filename: string) {
    if (
      !uploadFilenamePattern.test(filename) ||
      !(await this.canRead(userId, `/public/uploads/${filename}`))
    )
      throw new NotFoundException("Image not available");
    try {
      const root = await lstat(this.root());
      if (!root.isDirectory() || root.isSymbolicLink())
        throw new Error("Unsafe upload directory");
      const file = await open(
        join(this.root(), filename),
        constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK,
      );
      let stat;
      try {
        stat = await file.stat();
        if (!stat.isFile() || stat.nlink !== 1)
          throw new Error("Unsafe media file");
      } catch (error) {
        await file.close().catch(() => undefined);
        throw error;
      }
      return {
        file,
        mime: filename.toLowerCase().endsWith(".jpeg")
          ? "image/jpeg"
          : (Object.entries(imageExtensions).find(([, extension]) =>
              filename.toLowerCase().endsWith(extension),
            )?.[0] ?? "application/octet-stream"),
        bytes: stat.size,
      };
    } catch {
      throw new NotFoundException("Image not available");
    }
  }
}
