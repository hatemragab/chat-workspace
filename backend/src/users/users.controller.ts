import { Controller, Get } from "@nestjs/common";
import { ApiBearerAuth, ApiTags } from "@nestjs/swagger";
import { DatabaseService } from "../infrastructure/database.service";
@ApiTags("users")
@ApiBearerAuth()
@Controller("users")
export class UsersController {
  constructor(private readonly db: DatabaseService) {}
  @Get()
  async users() {
    return (
      await this.db.users
        .find()
        .select("_id username displayName avatarUrl")
        .sort({ displayName: 1 })
        .lean()
    ).map((user) => ({
      _id: user._id.toString(),
      id: user._id.toString(),
      username: user.username,
      displayName: user.displayName,
      avatarUrl: user.avatarUrl,
    }));
  }
}
