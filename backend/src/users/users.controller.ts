import {
  Controller,
  Get,
  PayloadTooLargeException,
  Query,
} from "@nestjs/common";
import { ConfigService } from "@nestjs/config";
import { ApiBearerAuth, ApiTags } from "@nestjs/swagger";
import { Transform, Type } from "class-transformer";
import { IsInt, IsMongoId, IsOptional, Max, Min } from "class-validator";
import { Types } from "mongoose";
import { DatabaseService } from "../infrastructure/database.service";
import { boundedSetting } from "../infrastructure/bounded-work";
export class UsersQuery {
  @IsOptional() @Type(() => Number) @IsInt() @Min(1) @Max(100) limit?: number;
  @IsOptional()
  @Transform(({ value }: { value: unknown }) =>
    typeof value === "string" ? value.toLowerCase() : value,
  )
  @IsMongoId()
  afterUserId?: string;
}
@ApiTags("users")
@ApiBearerAuth()
@Controller("users")
export class UsersController {
  constructor(
    private readonly db: DatabaseService,
    private readonly config: ConfigService,
  ) {}
  @Get()
  async users(@Query() query: UsersQuery) {
    const paged = query.limit !== undefined || query.afterUserId !== undefined;
    const limit = paged
      ? (query.limit ?? 100)
      : boundedSetting(
          this.config,
          "LEGACY_DIRECTORY_MAX_USERS",
          10000,
          100000,
        );
    const rows = await this.db.users
      .find(
        query.afterUserId
          ? { _id: { $gt: new Types.ObjectId(query.afterUserId) } }
          : {},
      )
      .select("_id username displayName avatarUrl")
      .sort(paged ? { _id: 1 } : { displayName: 1, _id: 1 })
      .limit(limit + 1)
      .lean();
    if (!paged && rows.length > limit)
      throw new PayloadTooLargeException(
        "Use limit and paginated user discovery for this dataset",
      );
    const users = rows.slice(0, limit).map((user) => ({
      _id: user._id.toString(),
      id: user._id.toString(),
      username: user.username,
      displayName: user.displayName,
      avatarUrl: user.avatarUrl,
    }));
    return paged
      ? { users, nextCursor: rows.length > limit ? users.at(-1)!._id : null }
      : users;
  }
}
