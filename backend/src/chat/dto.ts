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
  ValidateIf,
  ValidateNested,
} from "class-validator";
const normalizeId = ({ value }: { value: unknown }) =>
  typeof value === "string" ? value.toLowerCase() : value;
const normalizeIds = ({ value }: { value: unknown }) =>
  Array.isArray(value)
    ? value.map((id: unknown) =>
        typeof id === "string" ? id.toLowerCase() : id,
      )
    : value;
export class GroupDto {
  @IsString() @Length(1, 100) title!: string;
  @IsArray()
  @Transform(normalizeIds)
  @ArrayMinSize(1)
  @ArrayMaxSize(99)
  @ArrayUnique()
  @IsMongoId({ each: true })
  participantIds!: string[];
  @IsOptional() @IsString() @Length(1, 500) avatarUrl?: string;
}
export class PreferencesDto {
  @ValidateIf((_object, value: unknown) => value !== undefined)
  @IsBoolean()
  pin?: boolean;
  @ValidateIf((_object, value: unknown) => value !== undefined)
  @IsBoolean()
  isMuted?: boolean;
}
export class SendMessageDto {
  @IsOptional() @Transform(normalizeId) @IsMongoId() roomId?: string;
  @IsOptional() @Transform(normalizeId) @IsMongoId() peerUserId?: string;
  @IsUUID("4") idempotencyKey!: string;
  @IsIn(["text", "image"]) type!: "text" | "image";
  @IsString() @Length(0, 10000) text!: string;
  @IsOptional() @IsString() @Length(1, 500) imageUrl?: string;
  @IsOptional() @Transform(normalizeId) @IsMongoId() replyToMessageId?: string;
}
export class EditMessageDto {
  @IsString() @Length(1, 10000) text!: string;
}
export class BoundaryDto {
  @ValidateIf((_object, value: unknown) => value !== undefined)
  @IsISO8601({ strict: true })
  upToTimestamp?: string;
  @ValidateIf((_object, value: unknown) => value !== undefined)
  @IsInt()
  @Min(0)
  @Max(Number.MAX_SAFE_INTEGER)
  upToSeq?: number;
}
export class DeliveryTargetDto {
  @Transform(normalizeId) @IsMongoId() roomId!: string;
  @IsInt() @Min(0) @Max(Number.MAX_SAFE_INTEGER) upToSeq!: number;
}
export class DeliveredBatchDto extends BoundaryDto {
  @ValidateIf((_object, value: unknown) => value !== undefined)
  @IsArray()
  @Transform(normalizeIds)
  @ArrayMinSize(1)
  @ArrayMaxSize(100)
  @ArrayUnique()
  @IsMongoId({ each: true })
  roomIds?: string[];
  @ValidateIf((_object, value: unknown) => value !== undefined)
  @IsArray()
  @ArrayMinSize(1)
  @ArrayMaxSize(100)
  @ValidateNested({ each: true })
  @Type(() => DeliveryTargetDto)
  targets?: DeliveryTargetDto[];
}
export class RoomsQuery {
  @IsOptional() @Type(() => Number) @IsInt() @Min(1) @Max(100) limit = 25;
  @IsOptional() @IsISO8601({ strict: true }) beforeSortTimestamp?: string;
  @IsOptional() @Transform(normalizeId) @IsMongoId() beforeRoomId?: string;
  @IsOptional()
  @Type(() => Number)
  @IsInt()
  @Min(1)
  @Max(100)
  pinnedLimit?: number;
  @IsOptional() @IsISO8601({ strict: true }) beforePinAt?: string;
  @IsOptional()
  @Transform(normalizeId)
  @IsMongoId()
  beforePinnedRoomId?: string;
  @IsOptional()
  @Transform(({ value }: { value: unknown }) =>
    value === "true" ? true : value === "false" ? false : value,
  )
  @IsBoolean()
  pinnedOnly?: boolean;
}
export class MessagesQuery {
  @IsOptional() @Type(() => Number) @IsInt() @Min(1) @Max(100) limit = 30;
  @IsOptional() @IsISO8601({ strict: true }) beforeCreatedAt?: string;
  @IsOptional() @Transform(normalizeId) @IsMongoId() beforeId?: string;
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
  @Transform(normalizeIds)
  @IsArray()
  @ArrayMaxSize(100)
  @IsMongoId({ each: true })
  userIds!: string[];
}
