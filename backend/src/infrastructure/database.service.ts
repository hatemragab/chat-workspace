import { Injectable, OnModuleDestroy, OnModuleInit } from "@nestjs/common";
import { InjectConnection } from "@nestjs/mongoose";
import { Connection, Model } from "mongoose";
import {
  UserSchema,
  RoomSchema,
  RoomMemberSchema,
  MessageSchema,
  User,
  Room,
  RoomMember,
  Message,
  UploadSchema,
  Upload,
} from "../models";
import { LocalServiceDiagnostics } from "./local-service-diagnostics";

@Injectable()
export class DatabaseService implements OnModuleInit, OnModuleDestroy {
  readonly users: Model<User>;
  readonly rooms: Model<Room>;
  readonly members: Model<RoomMember>;
  readonly messages: Model<Message>;
  readonly uploads: Model<Upload>;
  private readonly detachDiagnostics: () => void;
  constructor(
    @InjectConnection() readonly connection: Connection,
    diagnostics: LocalServiceDiagnostics,
  ) {
    this.detachDiagnostics = diagnostics.observeMongo(connection.getClient());
    this.users = connection.model<User>("User", UserSchema);
    this.rooms = connection.model<Room>("Room", RoomSchema);
    this.members = connection.model<RoomMember>("RoomMember", RoomMemberSchema);
    this.messages = connection.model<Message>("Message", MessageSchema);
    this.uploads = connection.model<Upload>("Upload", UploadSchema);
  }
  onModuleDestroy() {
    this.detachDiagnostics();
  }
  async ping(timeoutMs = 1500): Promise<void> {
    const db = this.connection.db;
    if (!db || this.connection.readyState !== 1)
      throw new Error("Database is not connected");
    // Driver CSOT bounds server selection, checkout and the command together.
    // Bypass Mongoose buffering and check the primary used by mutations.
    await db
      .admin()
      .command(
        { ping: 1 },
        { timeoutMS: timeoutMs, readPreference: "primary" },
      );
  }
  async onModuleInit() {
    // Create only the approved indexes; never drop indexes on an existing database.
    await Promise.all([
      this.users.createIndexes(),
      this.rooms.createIndexes(),
      this.members.createIndexes(),
      this.messages.createIndexes(),
      this.uploads.createIndexes(),
    ]);
  }
}
