import { Module } from "@nestjs/common";
import { ChatService } from "./chat.service";
import {
  MessagesController,
  ObjectIdPipe,
  RoomsController,
} from "./chat.controller";
import { UploadsController } from "./uploads.controller";
@Module({
  controllers: [RoomsController, MessagesController, UploadsController],
  providers: [ChatService, ObjectIdPipe],
})
export class ChatModule {}
