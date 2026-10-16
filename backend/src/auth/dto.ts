import {
  IsEmail,
  IsInt,
  IsOptional,
  IsString,
  Length,
  Matches,
  Max,
  Min,
} from "class-validator";
export class DebugLoginDto {
  @IsInt() @Min(1) @Max(5) debugUserNumber!: number;
}
export class SignupDto {
  @IsString() @Length(3, 40) @Matches(/^[a-zA-Z0-9_]+$/) username!: string;
  @IsEmail() @Length(3, 254) email!: string;
  @IsString() @Length(8, 72) password!: string;
  @IsString() @Length(1, 80) displayName!: string;
}
export class LoginDto {
  @IsOptional() @IsEmail() email?: string;
  @IsOptional() @IsString() @Length(1, 40) username?: string;
  @IsString() @Length(1, 72) password!: string;
}
