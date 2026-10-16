import {
  BadRequestException,
  ConflictException,
  Injectable,
  NotFoundException,
  OnModuleInit,
  UnauthorizedException,
} from "@nestjs/common";
import { ConfigService } from "@nestjs/config";
import { JwtService } from "@nestjs/jwt";
import * as bcrypt from "bcrypt";
import { randomBytes } from "node:crypto";
import { DatabaseService } from "../infrastructure/database.service";
import { User, userDto } from "../models";
import { LoginDto, SignupDto } from "./dto";

@Injectable()
export class AuthService implements OnModuleInit {
  constructor(
    private readonly db: DatabaseService,
    private readonly jwt: JwtService,
    private readonly config: ConfigService,
  ) {}
  async onModuleInit() {
    if (this.config.get("NODE_ENV") !== "development") return;
    const passwordHash = await bcrypt.hash(randomBytes(32).toString("hex"), 12);
    for (let n = 1; n <= 5; n++) {
      await this.db.users.updateOne(
        { username: `debug_user_${n}` },
        {
          $setOnInsert: {
            username: `debug_user_${n}`,
            email: `debug${n}@chat.local`,
            passwordHash,
            displayName: `User ${n}`,
            isDebugUser: true,
            debugUserNumber: n,
          },
        },
        { upsert: true },
      );
    }
  }
  requireDebug() {
    if (this.config.get("NODE_ENV") !== "development")
      throw new NotFoundException();
  }
  async debugUsers() {
    this.requireDebug();
    return (
      await this.db.users
        .find({ isDebugUser: true })
        .sort({ debugUserNumber: 1 })
        .lean()
    ).map(userDto);
  }
  async debugLogin(number: number) {
    this.requireDebug();
    const user = await this.db.users
      .findOne({ isDebugUser: true, debugUserNumber: number })
      .lean();
    if (!user) throw new NotFoundException("Debug user not available");
    return this.session(user);
  }
  async signup(dto: SignupDto) {
    if (!dto.displayName.trim())
      throw new BadRequestException("Display name is required");
    if (Buffer.byteLength(dto.password, "utf8") > 72)
      throw new BadRequestException("Password must not exceed 72 UTF-8 bytes");
    try {
      const user = await this.db.users.create({
        username: dto.username.toLowerCase(),
        email: dto.email.toLowerCase(),
        displayName: dto.displayName.trim(),
        passwordHash: await bcrypt.hash(dto.password, 12),
      });
      return this.session(user.toObject());
    } catch (error) {
      if ((error as { code?: number }).code === 11000)
        throw new ConflictException("Username or email already exists");
      throw error;
    }
  }
  async login(dto: LoginDto) {
    if (!dto.email && !dto.username)
      throw new BadRequestException("Email or username is required");
    const user = await this.db.users
      .findOne(
        dto.email
          ? { email: dto.email.toLowerCase() }
          : { username: dto.username!.toLowerCase() },
      )
      .select("+passwordHash")
      .lean();
    const hash =
      user?.passwordHash ??
      "$2b$12$QBM8Qt8uyLmQ0IWRQU3ZZOq7x1VIVjbS2za4n7uBx.44SvZOGD1BK";
    if (
      !(await bcrypt.compare(dto.password, hash)) ||
      !user ||
      user.isDebugUser
    )
      throw new UnauthorizedException("Invalid credentials");
    return this.session(user);
  }
  async centrifugoToken(userId: string) {
    return this.jwt.signAsync(
      { sub: userId },
      {
        secret: this.config.getOrThrow<string>(
          "CENTRIFUGO_TOKEN_HMAC_SECRET_KEY",
        ),
        expiresIn: "1h",
        algorithm: "HS256",
      },
    );
  }
  private async session(user: User) {
    const accessToken = await this.jwt.signAsync(
      { sub: user._id.toString() },
      {
        secret: this.config.getOrThrow<string>("JWT_SECRET"),
        expiresIn: "1d",
        algorithm: "HS256",
        issuer: "chat-backend",
        audience: "chat-client",
      },
    );
    return {
      user: userDto(user),
      accessToken,
      centrifugoToken: await this.centrifugoToken(user._id.toString()),
    };
  }
}
