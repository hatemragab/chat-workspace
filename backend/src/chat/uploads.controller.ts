import {
  BadRequestException,
  Controller,
  Post,
  UploadedFile,
  UseInterceptors,
} from "@nestjs/common";
import { ApiBearerAuth, ApiTags } from "@nestjs/swagger";
import { FileInterceptor } from "@nestjs/platform-express";
import { randomUUID } from "node:crypto";
import { mkdir, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { memoryStorage } from "multer";
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
      buffer.subarray(0, 3).equals(Buffer.from([0xff, 0xd8, 0xff]))
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
@ApiTags("uploads")
@ApiBearerAuth()
@Controller("uploads")
export class UploadsController {
  @Post("image")
  @UseInterceptors(
    FileInterceptor("file", {
      storage: memoryStorage(),
      limits: { fileSize: 5 * 1024 * 1024, files: 1, fields: 0 },
      fileFilter: (_req, file, cb) => {
        if (!imageExtensions[file.mimetype])
          cb(
            new BadRequestException(
              "Only JPEG, PNG, WebP and GIF images are accepted",
            ),
            false,
          );
        else cb(null, true);
      },
    }),
  )
  async image(@UploadedFile() file?: Express.Multer.File) {
    if (!file || !hasImageSignature(file.buffer, file.mimetype))
      throw new BadRequestException("A valid image file is required");
    const filename = `${randomUUID()}${imageExtensions[file.mimetype]}`;
    await mkdir(join(process.cwd(), "public/uploads"), { recursive: true });
    await writeFile(
      join(process.cwd(), "public/uploads", filename),
      file.buffer,
      { flag: "wx", mode: 0o600 },
    );
    return { imageUrl: `/public/uploads/${filename}` };
  }
}
