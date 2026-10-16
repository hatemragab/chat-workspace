import { Transform, Type } from "class-transformer";
import {
  ArrayMaxSize,
  ArrayMinSize,
  ArrayUnique,
  IsArray,
  IsBoolean,
  IsIn,
  IsInt,
  IsISO8601,
  IsMongoId,
  IsOptional,
  IsString,
  IsUUID,
  Length,
  Max,
  Min,
} from "class-validator";
export class GroupDto {
  @IsString() @Length(1, 100) title!: string;
  @IsArray()
  @ArrayMinSize(1)
  @ArrayMaxSize(99)
  @ArrayUnique()
  @IsMongoId({ each: true })
  participantIds!: string[];
  @IsOptional() @IsString() @Length(1, 500) avatarUrl?: string;
}
export class PreferencesDto {
  @IsOptional() @IsBoolean() pin?: boolean;
  @IsOptional() @IsBoolean() isMuted?: boolean;
}
export class SendMessageDto {
  @IsOptional() @IsMongoId() roomId?: string;
  @IsOptional() @IsMongoId() peerUserId?: string;
  @IsUUID("4") idempotencyKey!: string;
  @IsIn(["text", "image"]) type!: "text" | "image";
  @IsString() @Length(0, 10000) text!: string;
  @IsOptional() @IsString() @Length(1, 500) imageUrl?: string;
  @IsOptional() @IsMongoId() replyToMessageId?: string;
}
export class EditMessageDto {
  @IsString() @Length(1, 10000) text!: string;
}
export class BoundaryDto {
  @IsOptional() @IsISO8601({ strict: true }) upToTimestamp?: string;
}
export class DeliveredBatchDto extends BoundaryDto {
  @IsArray()
  @ArrayMinSize(1)
  @ArrayMaxSize(100)
  @ArrayUnique()
  @IsMongoId({ each: true })
  roomIds!: string[];
}
export class RoomsQuery {
  @IsOptional() @Type(() => Number) @IsInt() @Min(1) @Max(100) limit = 25;
  @IsOptional() @IsISO8601({ strict: true }) beforeSortTimestamp?: string;
  @IsOptional() @IsMongoId() beforeRoomId?: string;
}
export class MessagesQuery {
  @IsOptional() @Type(() => Number) @IsInt() @Min(1) @Max(100) limit = 30;
  @IsOptional() @IsISO8601({ strict: true }) beforeCreatedAt?: string;
  @IsOptional() @IsMongoId() beforeId?: string;
}
export class DeltaQuery {
  @Type(() => Number)
  @IsInt()
  @Min(0)
  @Max(Number.MAX_SAFE_INTEGER)
  sincePts!: number;
  @IsString() @Length(0, 100) epoch!: string;
}
export class PresenceQuery {
  @Transform(({ value }: { value: unknown }) =>
    typeof value === "string" && value ? value.split(",") : value,
  )
  @IsArray()
  @ArrayMaxSize(100)
  @IsMongoId({ each: true })
  userIds!: string[];
}
