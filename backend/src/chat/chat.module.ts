import { Module } from "@nestjs/common";
import { ChatService } from "./chat.service";
import {
  MessagesController,
  ObjectIdPipe,
  RoomsController,
} from "./chat.controller";
import {
  MediaController,
  UploadBudgetGuard,
  UploadsController,
} from "./uploads.controller";
import { UploadsService } from "./uploads.service";
@Module({
  controllers: [
    RoomsController,
    MessagesController,
    UploadsController,
    MediaController,
  ],
  providers: [ChatService, ObjectIdPipe, UploadsService, UploadBudgetGuard],
})
export class ChatModule {}
