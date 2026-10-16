import { Injectable, OnModuleInit } from "@nestjs/common";
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
} from "../models";

@Injectable()
export class DatabaseService implements OnModuleInit {
  readonly users: Model<User>;
  readonly rooms: Model<Room>;
  readonly members: Model<RoomMember>;
  readonly messages: Model<Message>;
  constructor(@InjectConnection() readonly connection: Connection) {
    this.users = connection.model<User>("User", UserSchema);
    this.rooms = connection.model<Room>("Room", RoomSchema);
    this.members = connection.model<RoomMember>("RoomMember", RoomMemberSchema);
    this.messages = connection.model<Message>("Message", MessageSchema);
  }
  async onModuleInit() {
    // Create only the approved indexes; never drop indexes on an existing database.
    await Promise.all([
      this.users.createIndexes(),
      this.rooms.createIndexes(),
      this.members.createIndexes(),
      this.messages.createIndexes(),
    ]);
  }
}
