import 'dart:async';
import 'dart:typed_data';

import 'package:chat_workspace/core/exports.dart';
import 'package:drift/native.dart';

class FakeChatController extends ChatController {
  FakeChatController({bool authenticated = true})
    : super(
        database: AppDatabase(NativeDatabase.memory()),
        enableRealtime: false,
      ) {
    initialized = true;
    if (authenticated) currentUser = me;
    users = [peer];
    connectionStatus = 'Connected';
  }
  static const me = UserProfile(
    id: 'user-1',
    username: 'user1',
    displayName: 'User 1',
  );
  static const peer = UserProfile(
    id: 'user-2',
    username: 'user2',
    displayName: 'User 2',
  );
  String? sentText;
  String? requestedJump;
  List<ChatMessage> jumpResults = [];
  List<ChatMessage> latestMessages = [];
  Duration jumpDelay = Duration.zero;
  bool jumpUsesAround = false;
  int returnToLatestCalls = 0;
  Timer? _jumpTimer;
  final sentImages = <String>[];
  bool failImageSend = false;
  final retriedMessages = <String>[];
  @override
  Future<void> jumpToMessage(String targetId) async {
    requestedJump = targetId;
    highlightMessageId = targetId;
    _jumpTimer = Timer(jumpDelay, () {
      isJumpMode = jumpUsesAround;
      messages = jumpResults;
      notifyListeners();
    });
    notifyListeners();
  }

  @override
  Future<void> returnToLatest() async {
    returnToLatestCalls++;
    isJumpMode = false;
    messages = latestMessages;
    notifyListeners();
  }

  @override
  Future<void> sendImage(
    Uint8List bytes,
    String filename, {
    ChatMessage? replyTo,
  }) async {
    sentImages.add(filename);
    if (failImageSend) error = 'Image upload failed';
    notifyListeners();
  }

  @override
  Future<void> retryMessage(ChatMessage message) async {
    retriedMessages.add(message.id);
    messages = messages
        .map((m) => m.id == message.id ? m.copyWith(status: 'sent') : m)
        .toList();
    notifyListeners();
  }

  void publishRooms(List<ChatRoom> value) {
    rooms = value;
    notifyListeners();
  }

  void publishMessages(List<ChatMessage> value) {
    messages = value;
    notifyListeners();
  }

  @override
  void dispose() {
    _jumpTimer?.cancel();
    super.dispose();
  }

  ChatMessage? repliedTo;
  final preferenceChanges = <String>[];
  final deletedMessages = <String>[];
  int? debugNumber;
  bool? deletedForEveryone;
  int openedDrafts = 0;
  int syncs = 0;
  @override
  Future<void> initialize() async {}
  @override
  Future<void> debugLogin(int number) async {
    debugNumber = number;
    currentUser = me;
    notifyListeners();
  }

  @override
  Future<void> refreshUsers() async {}
  @override
  Future<void> openDirect(UserProfile peer) async {
    openedDrafts++;
    draftPeer = peer;
    selectedRoom = null;
    messages = [];
    notifyListeners();
  }

  @override
  Future<void> openRoom(ChatRoom room) async {
    selectedRoom = room;
    draftPeer = null;
    notifyListeners();
  }

  @override
  Future<void> sendText(String text, {ChatMessage? replyTo}) async {
    sentText = text;
    repliedTo = replyTo;
    notifyListeners();
  }

  @override
  Future<void> editMessage(ChatMessage message, String text) async {
    messages = messages
        .map(
          (m) => m.id == message.id
              ? ChatMessage.fromJson({
                  ...m.toJson(),
                  'text': text,
                  'isEdited': true,
                })
              : m,
        )
        .toList();
    notifyListeners();
  }

  @override
  Future<void> deleteMessage(
    ChatMessage message, {
    required bool forEveryone,
  }) async {
    deletedMessages.add(message.id);
    deletedForEveryone = forEveryone;
    messages = messages.where((m) => m.id != message.id).toList();
    notifyListeners();
  }

  @override
  Future<void> setPreferences(ChatRoom room, {bool? pin, bool? isMuted}) async {
    preferenceChanges.add('${room.roomId}:pin=$pin:mute=$isMuted');
    notifyListeners();
  }

  @override
  Future<void> logout() async {
    currentUser = null;
    selectedRoom = null;
    draftPeer = null;
    rooms = [];
    messages = [];
    notifyListeners();
  }

  @override
  Future<void> syncNow() async {
    syncs++;
  }

  @override
  Future<Map<String, Object?>> inspectDatabase() async => {
    'metadata': {'localPts': 7},
    'rooms': [],
    'messages': [],
  };
  void openFixture() {
    selectedRoom = ChatRoom(
      roomId: 'room-1',
      roomType: 'direct',
      displayTitle: 'User 2',
      peerUserId: 'user-2',
      sortTimestamp: DateTime.utc(2026, 10, 16),
    );
    rooms = [selectedRoom!];
    messages = [
      ChatMessage(
        id: 'message-1',
        idempotencyKey: 'key-1',
        roomId: 'room-1',
        senderId: me.id,
        senderName: me.displayName,
        type: 'text',
        text: 'Hello from the test',
        createdAt: DateTime.utc(2026, 10, 16, 12),
        deliveredAt: DateTime.utc(2026, 10, 16, 12, 1),
      ),
    ];
  }
}
