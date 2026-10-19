import {
  BadRequestException,
  Body,
  Controller,
  Delete,
  Get,
  HttpCode,
  Injectable,
  Param,
  Patch,
  PipeTransform,
  Post,
  Query,
} from "@nestjs/common";
import { ApiBearerAuth, ApiTags } from "@nestjs/swagger";
import { CurrentUser } from "../auth/auth.guard";
import { ChatService } from "./chat.service";
import {
  BoundaryDto,
  DeliveredBatchDto,
  DeltaQuery,
  EditMessageDto,
  GroupDto,
  MessagesQuery,
  PreferencesDto,
  RoomsQuery,
  SendMessageDto,
} from "./dto";
@Injectable()
export class ObjectIdPipe implements PipeTransform<string, string> {
  transform(value: string) {
    if (!/^[0-9a-f]{24}$/i.test(value))
      throw new BadRequestException("Invalid resource identifier");
    return value.toLowerCase();
  }
}
@ApiTags("rooms")
@ApiBearerAuth()
@Controller("rooms")
export class RoomsController {
  constructor(private readonly chat: ChatService) {}
  @Get("delta") delta(@CurrentUser() user: string, @Query() query: DeltaQuery) {
    return this.chat.delta(user, query);
  }
  @Get() rooms(@CurrentUser() user: string, @Query() query: RoomsQuery) {
    return this.chat.rooms(user, query);
  }
  @Get("direct-peer/:peerUserId") peer(
    @CurrentUser() user: string,
    @Param("peerUserId", ObjectIdPipe) peer: string,
  ) {
    return this.chat.directPeer(user, peer);
  }
  @Post("group") group(@CurrentUser() user: string, @Body() dto: GroupDto) {
    return this.chat.createGroup(user, dto);
  }
  @Post("delivered-batch") @HttpCode(200) deliveredBatch(
    @CurrentUser() user: string,
    @Body() dto: DeliveredBatchDto,
  ) {
    return this.chat.deliveredBatch(user, dto);
  }
  @Patch(":roomId/preferences") preferences(
    @CurrentUser() user: string,
    @Param("roomId", ObjectIdPipe) room: string,
    @Body() dto: PreferencesDto,
  ) {
    return this.chat.preferences(user, room, dto);
  }
  @Get(":roomId/messages") messages(
    @CurrentUser() user: string,
    @Param("roomId", ObjectIdPipe) room: string,
    @Query() query: MessagesQuery,
  ) {
    return this.chat.messages(user, room, query);
  }
  @Get(":roomId/messages/around/:targetMessageId") around(
    @CurrentUser() user: string,
    @Param("roomId", ObjectIdPipe) room: string,
    @Param("targetMessageId", ObjectIdPipe) target: string,
    @Query() query: MessagesQuery,
  ) {
    return this.chat.around(user, room, target, query);
  }
  @Post(":roomId/delivered") @HttpCode(200) delivered(
    @CurrentUser() user: string,
    @Param("roomId", ObjectIdPipe) room: string,
    @Body() dto: BoundaryDto,
  ) {
    return this.chat.delivered(user, [room], dto);
  }
  @Post(":roomId/seen") @HttpCode(200) seen(
    @CurrentUser() user: string,
    @Param("roomId", ObjectIdPipe) room: string,
    @Body() dto: BoundaryDto,
  ) {
    return this.chat.seen(user, room, dto);
  }
}
@ApiTags("messages")
@ApiBearerAuth()
@Controller("messages")
export class MessagesController {
  constructor(private readonly chat: ChatService) {}
  @Post() @HttpCode(200) send(
    @CurrentUser() user: string,
    @Body() dto: SendMessageDto,
  ) {
    return this.chat.send(user, dto);
  }
  @Patch(":messageId") edit(
    @CurrentUser() user: string,
    @Param("messageId", ObjectIdPipe) message: string,
    @Body() dto: EditMessageDto,
  ) {
    return this.chat.edit(user, message, dto);
  }
  @Delete(":messageId/for-all") removeAll(
    @CurrentUser() user: string,
    @Param("messageId", ObjectIdPipe) message: string,
  ) {
    return this.chat.deleteForAll(user, message);
  }
  @Delete(":messageId/for-me") removeMe(
    @CurrentUser() user: string,
    @Param("messageId", ObjectIdPipe) message: string,
  ) {
    return this.chat.deleteForMe(user, message);
  }
}
