import {
  CanActivate,
  Controller,
  ExecutionContext,
  Get,
  Injectable,
  Param,
  Post,
  Res,
  UploadedFile,
  UseGuards,
  UseInterceptors,
  HttpException,
} from "@nestjs/common";
import { ConfigService } from "@nestjs/config";
import { ApiBearerAuth, ApiTags } from "@nestjs/swagger";
import { FileInterceptor } from "@nestjs/platform-express";
import { memoryStorage } from "multer";
import { Response } from "express";
import { CurrentUser, AuthRequest } from "../auth/auth.guard";
import { RedisSyncService } from "../infrastructure/redis-sync.service";
import { boundedSetting } from "../infrastructure/bounded-work";
import { imageExtensions, UploadsService } from "./uploads.service";
export { hasImageSignature, imageExtensions } from "./uploads.service";

@Injectable()
export class UploadBudgetGuard implements CanActivate {
  private active = 0;
  private readonly users = new Map<string, number>();
  constructor(
    private readonly config: ConfigService,
    private readonly redis: RedisSyncService,
  ) {}
  async canActivate(context: ExecutionContext) {
    const request = context.switchToHttp().getRequest<AuthRequest>();
    const response = context.switchToHttp().getResponse<Response>();
    await this.redis.limitRealtime(
      "upload",
      request.userId,
      request.ip ?? "unknown",
    );
    const userCount = this.users.get(request.userId) ?? 0;
    if (
      this.active >=
        boundedSetting(this.config, "UPLOAD_MAX_CONCURRENT", 4, 64) ||
      userCount >=
        boundedSetting(this.config, "UPLOAD_MAX_CONCURRENT_PER_USER", 2, 16)
    )
      throw new HttpException("Upload capacity reached. Retry later.", 429);
    this.active++;
    this.users.set(request.userId, userCount + 1);
    let released = false;
    const timer = setTimeout(
      () => response.destroy(),
      boundedSetting(this.config, "UPLOAD_REQUEST_TIMEOUT_MS", 30000, 120000),
    );
    const release = () => {
      if (released) return;
      released = true;
      clearTimeout(timer);
      this.active--;
      const count = (this.users.get(request.userId) ?? 1) - 1;
      if (count) this.users.set(request.userId, count);
      else this.users.delete(request.userId);
    };
    response.once("finish", release);
    response.once("close", release);
    return true;
  }
}

@ApiTags("uploads")
@ApiBearerAuth()
@Controller("uploads")
export class UploadsController {
  constructor(private readonly uploads: UploadsService) {}
  @Post("image")
  @UseGuards(UploadBudgetGuard)
  @UseInterceptors(
    FileInterceptor("file", {
      storage: memoryStorage(),
      limits: { fileSize: 5 * 1024 * 1024, files: 1, fields: 0 },
      fileFilter: (_request, file, callback) =>
        imageExtensions[file.mimetype]
          ? callback(null, true)
          : callback(
              new HttpException(
                "Only JPEG, PNG, WebP and GIF images are accepted",
                400,
              ),
              false,
            ),
    }),
  )
  image(
    @CurrentUser() user: string,
    @UploadedFile() file?: Express.Multer.File,
  ) {
    return this.uploads.store(user, file);
  }
}

@ApiTags("uploads")
@ApiBearerAuth()
@Controller("public/uploads")
export class MediaController {
  constructor(private readonly uploads: UploadsService) {}
  @Get(":filename")
  async image(
    @CurrentUser() user: string,
    @Param("filename") filename: string,
    @Res() response: Response,
  ) {
    const { file, mime, bytes } = await this.uploads.read(user, filename);
    response.set({
      "Content-Type": mime,
      "Content-Length": String(bytes),
      "Cache-Control": "private, no-store",
      "X-Content-Type-Options": "nosniff",
      "Content-Security-Policy": "default-src 'none'",
    });
    if (response.destroyed) {
      await file.close();
      return;
    }
    const stream = file.createReadStream({ autoClose: true });
    response.once("close", () => stream.destroy());
    stream.once("error", () => response.destroy());
    stream.pipe(response);
  }
}
