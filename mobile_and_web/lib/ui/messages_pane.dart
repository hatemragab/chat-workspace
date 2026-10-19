import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:v_chat_bubbles/v_chat_bubbles.dart';
import 'package:v_chat_input_ui/v_chat_input_ui.dart';

import '../core/exports.dart';
import 'theme.dart';
import 'private_media.dart';
import 'presence_label.dart';

class MessagesPane extends ConsumerStatefulWidget {
  const MessagesPane({super.key, this.compact = false});
  final bool compact;
  @override
  ConsumerState<MessagesPane> createState() => _MessagesPaneState();
}

class _MessagesPaneState extends ConsumerState<MessagesPane> {
  final _scroll = ScrollController();
  final _keys = <String, GlobalKey>{};
  ChatMessage? _reply;
  String? _roomIdentity;
  bool _loadingOlder = false;
  bool _uploading = false;
  String? _highlight;
  String? _pendingJumpId;
  int _jumpGeneration = 0;
  int _jumpScrollAttempts = 0;
  int _uploadGeneration = 0;
  int _replyGeneration = 0;
  final _unsavedTexts = <String>[];
  Timer? _highlightTimer;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    _highlightTimer?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    final c = ref.read(chatControllerProvider);
    if (_scroll.hasClients &&
        _scroll.position.pixels >= _scroll.position.maxScrollExtent - 100 &&
        c.hasMoreMessages &&
        !_loadingOlder &&
        !c.isJumpMode &&
        c.messages.isNotEmpty) {
      _loadOlder();
    }
  }

  Future<void> _loadOlder() async {
    if (_loadingOlder) return;
    final identity = _roomIdentity;
    setState(() => _loadingOlder = true);
    await ref.read(chatControllerProvider).loadOlderMessages();
    if (mounted && identity == _roomIdentity) {
      setState(() => _loadingOlder = false);
    }
  }

  void _replyTo(ChatMessage message) {
    if (message.isDeletedForAll || message.status != 'sent') return;
    setState(() {
      _reply = message;
      _replyGeneration++;
    });
  }

  Future<void> _send(String text) async {
    if (text.trim().isEmpty) return;
    final c = ref.read(chatControllerProvider);
    final sendContext = c.captureSendContext();
    if (sendContext == null) return;
    final identity = _roomIdentity;
    final reply = _reply;
    setState(() {
      _reply = null;
      _replyGeneration++;
    });
    if (c.isJumpMode) await c.returnToLatest();
    if (!c.isSendContextCurrent(sendContext)) return;
    final saved = await c.sendText(text, replyTo: reply, context: sendContext);
    if (!saved &&
        mounted &&
        identity == _roomIdentity &&
        c.isSendContextCurrent(sendContext)) {
      // The package composer clears immediately on submission. Retain a
      // selectable recovery copy if its asynchronous SQLite write fails.
      setState(() => _unsavedTexts.add(text));
    }
    if (mounted &&
        identity == _roomIdentity &&
        c.isSendContextCurrent(sendContext) &&
        _scroll.hasClients) {
      _scroll.animateTo(
        0,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    }
  }

  Future<void> _sendMedia(List<VPlatformFile> files) async {
    if (_uploading) return;
    final controller = ref.read(chatControllerProvider);
    final sendContext = controller.captureSendContext();
    if (sendContext == null) return;
    final identity = _roomIdentity;
    final generation = ++_uploadGeneration;
    final reply = _reply;
    final replyGeneration = _replyGeneration;
    setState(() => _uploading = true);
    try {
      if (controller.isJumpMode) await controller.returnToLatest();
      final valid = <({Uint8List bytes, String filename})>[];
      for (final file in files) {
        if (!controller.isSendContextCurrent(sendContext)) break;
        if (file.fileSize > 5 * 1024 * 1024 ||
            !const [
              'image/jpeg',
              'image/png',
              'image/webp',
              'image/gif',
            ].contains(file.mimeType)) {
          if (mounted && identity == _roomIdentity) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text(
                  'Choose a JPEG, PNG, WebP, or GIF image up to 5 MB.',
                ),
              ),
            );
          }
          continue;
        }
        valid.add((bytes: file.uint8List, filename: file.name));
      }
      if (valid.length == 1) {
        await controller.sendImage(
          valid.single.bytes,
          valid.single.filename,
          replyTo: reply,
          context: sendContext,
        );
      } else if (valid.isNotEmpty) {
        await controller.sendImageBatch(
          valid,
          replyTo: reply,
          context: sendContext,
        );
      }
      if (mounted &&
          identity == _roomIdentity &&
          generation == _uploadGeneration &&
          controller.isSendContextCurrent(sendContext) &&
          controller.error == null &&
          replyGeneration == _replyGeneration) {
        setState(() {
          _reply = null;
          _replyGeneration++;
        });
      }
    } catch (_) {
      if (mounted && identity == _roomIdentity) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'The image could not be read. Please select it again.',
            ),
          ),
        );
      }
    } finally {
      if (mounted && generation == _uploadGeneration) {
        setState(() => _uploading = false);
      }
    }
  }

  Future<void> _jump(String id) async {
    final c = ref.read(chatControllerProvider);
    final generation = ++_jumpGeneration;
    final roomIdentity = _roomIdentity;
    _highlightTimer?.cancel();
    setState(() {
      _pendingJumpId = null;
      _highlight = null;
    });
    await c.jumpToMessage(id);
    if (!mounted ||
        generation != _jumpGeneration ||
        roomIdentity != _roomIdentity ||
        c.error != null) {
      return;
    }
    _highlightTimer?.cancel();
    setState(() {
      _pendingJumpId = id;
      _jumpScrollAttempts = 0;
      _highlight = null;
    });
  }

  void _schedulePendingJump(ChatController controller) {
    final id = _pendingJumpId;
    if (id == null || !controller.messages.any((message) => message.id == id)) {
      return;
    }
    final generation = _jumpGeneration;
    // Restarting a Drift window emits asynchronously. Scroll only after the
    // target row from that expanded window has been built and laid out.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || generation != _jumpGeneration || _pendingJumpId != id) {
        return;
      }
      final target = _keys[id]?.currentContext;
      if (target == null) {
        if (_scroll.hasClients && _jumpScrollAttempts++ < 20) {
          final index = controller.messages.indexWhere((m) => m.id == id);
          final built = _keys.entries
              .where((entry) => entry.value.currentContext != null)
              .map(
                (entry) =>
                    controller.messages.indexWhere((m) => m.id == entry.key),
              )
              .where((i) => i >= 0)
              .toList();
          final forward =
              built.isEmpty || index > built.reduce((a, b) => a < b ? a : b);
          final offset = (_scroll.offset + (forward ? 400 : -400)).clamp(
            0.0,
            _scroll.position.maxScrollExtent,
          );
          _scroll.jumpTo(offset);
          setState(() {});
        }
        return;
      }
      setState(() {
        _pendingJumpId = null;
        _highlight = id;
      });
      Scrollable.ensureVisible(
        target,
        alignment: .45,
        duration: const Duration(milliseconds: 250),
      );
      _highlightTimer = Timer(const Duration(milliseconds: 1500), () {
        if (mounted) setState(() => _highlight = null);
      });
    });
  }

  ChatMessage? _find(String id) {
    for (final m in ref.read(chatControllerProvider).messages) {
      if (m.id == id) return m;
    }
    return null;
  }

  Future<void> _action(ChatMessage message, String action) async {
    final c = ref.read(chatControllerProvider);
    switch (action) {
      case 'reply':
        _replyTo(message);
      case 'copy':
        await Clipboard.setData(ClipboardData(text: message.text));
      case 'retry':
        await c.retryMessage(message);
      case 'edit':
        await _edit(message);
      case 'delete-me':
        await c.deleteMessage(message, forEveryone: false);
      case 'delete-all':
        await c.deleteMessage(message, forEveryone: true);
      case 'info':
        if (mounted) {
          await showDialog<void>(
            context: context,
            builder: (_) => AlertDialog(
              title: const Text('Message details'),
              content: SelectableText(
                'Sent: ${message.createdAt.toLocal()}\nDelivered: ${message.deliveredAt?.toLocal() ?? 'Pending'}\nSeen: ${message.seenAt?.toLocal() ?? 'Pending'}\nStatus: ${message.status}',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Close'),
                ),
              ],
            ),
          );
        }
    }
  }

  Future<void> _edit(ChatMessage message) async {
    final text = await showDialog<String>(
      context: context,
      builder: (_) => _EditMessageDialog(message: message),
    );
    if (text != null && mounted) {
      await ref.read(chatControllerProvider).editMessage(message, text);
    }
  }

  List<PopupMenuEntry<String>> _menu(ChatMessage message) {
    final mine =
        message.senderId == ref.read(chatControllerProvider).currentUser?.id;
    return [
      if (!message.isDeletedForAll && message.status == 'sent')
        const PopupMenuItem(value: 'reply', child: Text('Reply')),
      if (!message.isDeletedForAll && message.text.isNotEmpty)
        const PopupMenuItem(value: 'copy', child: Text('Copy text')),
      if (message.status == 'failed' || message.outboxPaused)
        const PopupMenuItem(value: 'retry', child: Text('Retry sending')),
      if (mine &&
          message.type == 'text' &&
          !message.isDeletedForAll &&
          message.status == 'sent')
        const PopupMenuItem(value: 'edit', child: Text('Edit message')),
      if (message.status == 'sent')
        const PopupMenuItem(value: 'delete-me', child: Text('Delete for me')),
      if (mine && !message.isDeletedForAll && message.status == 'sent')
        const PopupMenuItem(
          value: 'delete-all',
          child: Text('Delete for everyone'),
        ),
      const PopupMenuItem(value: 'info', child: Text('Message details')),
    ];
  }

  Future<void> _showActions(ChatMessage message, Offset position) async {
    final action = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy,
        position.dx,
        position.dy,
      ),
      items: _menu(message),
    );
    if (action != null) await _action(message, action);
  }

  @override
  Widget build(BuildContext context) {
    final c = ref.watch(chatControllerProvider);
    c.debugInspector.recordBuild(
      'MessagesPane',
      context: c.lastStateContext,
      notificationId: c.lastStateNotificationId,
    );
    final room = c.selectedRoom;
    final draft = c.draftPeer;
    final peerId = room?.peerUserId ?? draft?.id;
    // A lazy direct room keeps the same composer when its server ID arrives.
    // Account/session changes and actual conversation changes replace it.
    final conversation = room?.roomType == 'group'
        ? 'group_${room?.roomId}'
        : peerId != null
        ? 'direct_$peerId'
        : room?.roomId ?? 'none';
    final identity =
        '${c.currentUser?.id}:${c.sessionGenerationId}:$conversation';
    if (_roomIdentity != identity) {
      _roomIdentity = identity;
      _reply = null;
      _unsavedTexts.clear();
      _replyGeneration++;
      _keys.clear();
      _highlight = null;
      _pendingJumpId = null;
      _uploading = false;
      _loadingOlder = false;
      _uploadGeneration++;
      _highlightTimer?.cancel();
      _jumpGeneration++;
      if (_scroll.hasClients) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_scroll.hasClients) _scroll.jumpTo(0);
        });
      }
    }
    _keys.removeWhere(
      (id, key) => key.currentContext == null && id != _pendingJumpId,
    );
    _schedulePendingJump(c);
    final title = room?.displayTitle ?? draft?.displayName ?? '';
    final online = peerId != null && c.onlineUserIds.contains(peerId);
    final subtitle = room?.roomType == 'group'
        ? 'Group conversation'
        : presenceLabel(
            context,
            online: peerId == null ? null : c.userOnlineStatus(peerId),
            lastSeenAt: c.lastSeenAtByUserId[peerId],
            unknownLabel: draft != null
                ? 'Say hello to start this conversation'
                : 'Direct conversation',
          );
    final textScaler = MediaQuery.textScalerOf(context);
    final toolbarHeight =
        ((textScaler.scale(16) + textScaler.scale(12)) * 1.3 + 20).clamp(
          64.0,
          double.infinity,
        );
    return Column(
      children: [
        SizedBox(
          height: toolbarHeight,
          child: AppBar(
            key: const Key('conversation-app-bar'),
            primary: false,
            automaticallyImplyLeading: false,
            toolbarHeight: toolbarHeight,
            titleSpacing: widget.compact ? 0 : 24,
            leading: widget.compact
                ? IconButton(
                    key: const Key('back-to-conversations'),
                    tooltip: 'Back to conversations',
                    icon: const BackButtonIcon(),
                    onPressed: () {
                      FocusManager.instance.primaryFocus?.unfocus();
                      c.closeRoom();
                    },
                  )
                : null,
            title: Row(
              children: [
                ChatAvatar(
                  name: title,
                  id: identity,
                  url: c.imageUrl(room?.displayAvatarUrl ?? draft?.avatarUrl),
                  radius: 20,
                  online: online,
                  group: room?.roomType == 'group',
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        key: const Key('conversation-title'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: ChatColors.of(context).ink,
                          fontWeight: FontWeight.w700,
                          fontSize: 16,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        subtitle,
                        key: const Key('conversation-presence'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: online
                              ? ChatColors.online
                              : ChatColors.of(context).muted,
                          fontSize: 12,
                          fontWeight: FontWeight.w400,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            actions: [
              if (room != null && widget.compact)
                PopupMenuButton<String>(
                  tooltip: 'Conversation options',
                  onSelected: (value) {
                    if (value == 'pin') {
                      c.setPreferences(room, pin: room.pinAt == null);
                    }
                    if (value == 'mute') {
                      c.setPreferences(room, isMuted: !room.isMuted);
                    }
                  },
                  itemBuilder: (_) => [
                    PopupMenuItem(
                      key: const Key('pin-chat'),
                      value: 'pin',
                      child: Text(
                        room.pinAt == null ? 'Pin chat' : 'Unpin chat',
                      ),
                    ),
                    PopupMenuItem(
                      key: const Key('mute-chat'),
                      value: 'mute',
                      child: Text(room.isMuted ? 'Unmute chat' : 'Mute chat'),
                    ),
                  ],
                ),
              if (room != null && !widget.compact) ...[
                IconButton(
                  key: const Key('pin-chat'),
                  tooltip: room.pinAt == null ? 'Pin chat' : 'Unpin chat',
                  onPressed: () =>
                      c.setPreferences(room, pin: room.pinAt == null),
                  icon: Icon(
                    room.pinAt == null
                        ? Icons.push_pin_outlined
                        : Icons.push_pin,
                    size: 20,
                  ),
                ),
                IconButton(
                  key: const Key('mute-chat'),
                  tooltip: room.isMuted ? 'Unmute chat' : 'Mute chat',
                  onPressed: () =>
                      c.setPreferences(room, isMuted: !room.isMuted),
                  icon: Icon(
                    room.isMuted
                        ? Icons.notifications_off_outlined
                        : Icons.notifications_none_outlined,
                    size: 21,
                  ),
                ),
              ],
            ],
          ),
        ),
        Expanded(
          child: ColoredBox(
            color: ChatColors.of(context).chatCanvas,
            child: Stack(
              // The reversed viewport must fill the canvas even for short chats.
              fit: StackFit.expand,
              children: [
                const Positioned.fill(
                  child: IgnorePointer(
                    child: CustomPaint(painter: _ChatPattern()),
                  ),
                ),
                if (c.messages.isEmpty)
                  Center(
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            padding: const EdgeInsets.all(22),
                            decoration: BoxDecoration(
                              color: ChatColors.of(context).surface
                                  .withValues(alpha: .7),
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(
                              Icons.waving_hand_outlined,
                              size: 37,
                              color: ChatColors.primary,
                            ),
                          ),
                          const SizedBox(height: 20),
                          Text(
                            'Say hello to ${room?.roomType == 'group' ? 'the group' : title}',
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              fontSize: 21,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 9),
                          Text(
                            'Every good conversation starts somewhere.',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 13,
                              color: ChatColors.of(context).muted,
                            ),
                          ),
                          if (c.busy)
                            const Padding(
                              padding: EdgeInsets.all(16),
                              child: CircularProgressIndicator(),
                            ),
                        ],
                      ),
                    ),
                  )
                else
                  VBubbleScope(
                    style: VBubbleStyle.telegram,
                    theme: buildChatBubbleTheme(Theme.of(context).brightness),
                    config: const VBubbleConfig(
                      // Keep the package's non-wrapping deleted bubble compact;
                      // its full description remains in message semantics.
                      translations: VTranslationConfig(
                        deletedMessage: 'Deleted',
                      ),
                      gestures: VGestureConfig(
                        enableDoubleTapToReact: false,
                        enableHoverActions: false,
                      ),
                    ),
                    callbacks: VBubbleCallbacks(
                      onReplyPreviewTap: _jump,
                      onSwipeReply: (id) {
                        final m = _find(id);
                        if (m != null) _replyTo(m);
                      },
                      onLongPress: (id, position) {
                        final m = _find(id);
                        if (m != null) _showActions(m, position);
                      },
                      onRetryMessage: (id) {
                        final m = _find(id);
                        if (m != null) c.retryMessage(m);
                      },
                    ),
                    child: LayoutBuilder(
                      builder: (context, constraints) => CustomScrollView(
                        key: const Key('messages-scroll'),
                        controller: _scroll,
                        reverse: true,
                        slivers: [
                          SliverPadding(
                            padding: EdgeInsets.fromLTRB(
                              constraints.maxWidth > 850 ? 70 : 14,
                              20,
                              constraints.maxWidth > 850 ? 70 : 14,
                              c.isJumpMode ? 84 : 24,
                            ),
                            sliver: SliverList.builder(
                              itemCount:
                                  c.messages.length +
                                  (!c.isJumpMode && c.hasMoreMessages ? 1 : 0),
                              itemBuilder: (context, index) {
                                if (index == c.messages.length) {
                                  return Center(
                                    child: TextButton.icon(
                                      key: const Key('load-older-messages'),
                                      onPressed: _loadingOlder
                                          ? null
                                          : _loadOlder,
                                      icon: _loadingOlder
                                          ? const SizedBox(
                                              width: 14,
                                              height: 14,
                                              child: CircularProgressIndicator(
                                                strokeWidth: 2,
                                              ),
                                            )
                                          : const Icon(
                                              Icons.expand_less,
                                              size: 17,
                                            ),
                                      label: Text(
                                        _loadingOlder
                                            ? 'Loading history…'
                                            : 'Load earlier messages',
                                      ),
                                    ),
                                  );
                                }
                                return _message(c, c.messages[index]);
                              },
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                if (c.isJumpMode)
                  Positioned(
                    bottom: 20,
                    left: 0,
                    right: 0,
                    child: Center(
                      child: FilledButton.icon(
                        key: const Key('return-to-latest'),
                        onPressed: () async {
                          await c.returnToLatest();
                          if (mounted &&
                              identity == _roomIdentity &&
                              _scroll.hasClients) {
                            _scroll.jumpTo(0);
                          }
                        },
                        icon: const Icon(Icons.arrow_downward, size: 17),
                        label: const Text('Return to Latest Messages'),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        if (_uploading) const LinearProgressIndicator(minHeight: 2),
        if (c.connectionStatus.toLowerCase() != 'connected' &&
            c.connectionStatus.toLowerCase() != 'subscribed')
          Container(
            width: double.infinity,
            color: ChatColors.of(context).warning,
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
            child: Text(
              'Realtime ${c.connectionStatus}. Saved messages remain available.',
              style: TextStyle(
                fontSize: 11,
                color: ChatColors.of(context).onWarning,
              ),
            ),
          ),
        if (_unsavedTexts.isNotEmpty)
          Material(
            color: Theme.of(context).colorScheme.errorContainer,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Could not save this message on this device.'),
                  const Text('Copy the text before leaving this conversation.'),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 100),
                    child: SingleChildScrollView(
                      child: SelectableText(
                        _unsavedTexts.join('\n\n'),
                        key: const Key('unsaved-message-text'),
                      ),
                    ),
                  ),
                  TextButton.icon(
                    onPressed: () => Clipboard.setData(
                      ClipboardData(text: _unsavedTexts.join('\n\n')),
                    ),
                    icon: const Icon(Icons.copy, size: 16),
                    label: const Text('Copy unsaved text'),
                  ),
                ],
              ),
            ),
          ),
        Container(
          // Keep the composer mounted when connection/upload banners change.
          key: const Key('message-composer'),
          color: ChatColors.of(context).surface,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Semantics(
            // Keep the web text field's semantics node when Send appears.
            container: true,
            explicitChildNodes: true,
            label: 'Message composer',
            child: VMessageInputWidget(
              key: ValueKey('composer-$identity'),
              autofocus: false,
              language: const VInputLanguage(
                textFieldHint: 'Write a message…',
                sendButtonLabel: 'Send message',
                attachmentButtonLabel: 'Attach an image',
                media: 'Choose image',
              ),
              maxMediaSize: 5 * 1024 * 1024,
              enableVoiceRecording: false,
              enableCamera: false,
              showCameraLauncher: false,
              attachmentActions: const [
                VAttachmentAction.media(
                  label: 'Choose image',
                  icon: Icon(Icons.image_outlined),
                  semanticLabel: 'Choose image',
                ),
              ],
              enableEmojiPicker: false,
              onSubmitText: _send,
              onSubmitMedia: _sendMedia,
              onSubmitFiles: (_) {},
              onSubmitLocation: (_) {},
              onSubmitVoice: (_) {},
              onTypingChange: (_) {},
              replyWidget: _reply == null ? null : _replyBanner(_reply!),
            ),
          ),
        ),
      ],
    );
  }

  Widget _replyBanner(ChatMessage message) => Container(
    padding: const EdgeInsets.fromLTRB(16, 10, 4, 10),
    decoration: BoxDecoration(
      color: ChatColors.of(context).reply,
      border: Border(left: BorderSide(color: ChatColors.primary, width: 3)),
    ),
    child: Row(
      children: [
        const Icon(Icons.reply, color: ChatColors.primary, size: 23),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Reply to ${message.senderName}',
                style: const TextStyle(
                  color: ChatColors.primary,
                  fontWeight: FontWeight.w600,
                  fontSize: 12,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                message.type == 'image' ? 'Photo' : message.text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12),
              ),
            ],
          ),
        ),
        IconButton(
          tooltip: 'Cancel reply',
          onPressed: () => setState(() {
            _reply = null;
            _replyGeneration++;
          }),
          icon: const Icon(Icons.close, size: 19),
        ),
      ],
    ),
  );
  Widget _message(ChatController c, ChatMessage m) => PrivateMedia(
    key: ValueKey('media:${c.sessionGenerationId}:${m.id}'),
    api: c.api,
    paths: [
      if (m.imageUrl != null && !m.isDeletedForAll) m.imageUrl!,
      if (m.replyTo?.imageUrl != null && m.replyTo?.isDeleted != true)
        m.replyTo!.imageUrl!,
    ],
    builder: (bytes) => _messageWithBytes(c, m, bytes),
  );

  Widget _messageWithBytes(
    ChatController c,
    ChatMessage m,
    Map<String, Uint8List> bytes,
  ) {
    final mine = m.senderId == c.currentUser?.id;
    final time = m.createdAt.toLocal();
    final timeText =
        '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
    final reply = m.replyTo;
    final replyData = reply == null
        ? null
        : VReplyData(
            originalMessageId: reply.messageId,
            senderId: reply.senderId,
            senderName: reply.senderName,
            previewText: reply.isDeleted
                ? 'This message was deleted'
                : reply.type == 'image' && reply.text.isEmpty
                ? 'Photo'
                : reply.text,
            previewImage: bytes[reply.imageUrl]?.isNotEmpty != true
                ? null
                : VPlatformFile.fromBytes(
                    name: 'reply.png',
                    bytes: bytes[reply.imageUrl]!,
                  ),
            originalType: reply.type == 'image'
                ? VMessageType.image
                : VMessageType.text,
          );
    final status = m.outboxPaused
        ? VMessageStatus.error
        : const ['queued', 'sending'].contains(m.status)
        ? VMessageStatus.sending
        : m.status == 'failed'
        ? VMessageStatus.error
        : m.isSeen
        ? VMessageStatus.read
        : m.isDelivered
        ? VMessageStatus.delivered
        : VMessageStatus.sent;
    Widget bubble;
    if (m.isDeletedForAll) {
      bubble = VDeletedBubble(isMeSender: mine, time: timeText);
    } else if (m.type == 'image' &&
        (m.uploadBytes?.isNotEmpty == true ||
            bytes[m.imageUrl]?.isNotEmpty == true)) {
      bubble = VImageBubble(
        messageId: m.id,
        isMeSender: mine,
        time: timeText,
        imageFile: VPlatformFile.fromBytes(
          name: m.uploadFilename ?? 'image.png',
          bytes: m.uploadBytes ?? bytes[m.imageUrl]!,
        ),
        caption: m.text.isEmpty ? null : m.text,
        aspectRatio: 1.4,
        senderName: c.selectedRoom?.roomType == 'group' && !mine
            ? m.senderName
            : null,
        replyTo: replyData,
        status: status,
        isEdited: m.isEdited,
        isHighlighted: _highlight == m.id,
      );
    } else {
      bubble = VTextBubble(
        messageId: m.id,
        isMeSender: mine,
        time: timeText,
        text: m.type == 'image'
            ? (m.status == 'failed'
                  ? 'Image failed. Retry sending.'
                  : bytes.containsKey(m.imageUrl)
                  ? 'Image unavailable.'
                  : 'Loading image…')
            : m.text,
        status: status,
        senderName: c.selectedRoom?.roomType == 'group' && !mine
            ? m.senderName
            : null,
        replyTo: replyData,
        isEdited: m.isEdited,
        isHighlighted: _highlight == m.id,
      );
    }
    final key = _keys.putIfAbsent(m.id, GlobalKey.new);
    return Container(
      key: key,
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Semantics(
        label:
            '${m.senderName}: ${m.isDeletedForAll
                ? 'This message was deleted'
                : m.type == 'image'
                ? 'Photo ${m.text}'
                : m.text}${m.isEdited ? ', edited' : ''}${mine ? ', ${m.isSeen
                      ? 'seen'
                      : m.isDelivered
                      ? 'delivered'
                      : m.status}' : ''}',
        child: Column(
          crossAxisAlignment: mine
              ? CrossAxisAlignment.end
              : CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(child: bubble),
                PopupMenuButton<String>(
                  key: Key('message-actions-${m.id}'),
                  tooltip:
                      'Message actions: ${m.text.length > 40
                          ? m.text.substring(0, 40)
                          : m.text.isEmpty
                          ? 'Photo'
                          : m.text}',
                  padding: EdgeInsets.zero,
                  icon: Icon(
                    Icons.more_horiz,
                    size: 18,
                    color: ChatColors.of(context).muted,
                  ),
                  onSelected: (action) => _action(m, action),
                  itemBuilder: (_) => _menu(m),
                ),
              ],
            ),
            if (m.status == 'failed' || m.outboxPaused)
              Padding(
                padding: const EdgeInsets.only(right: 40),
                child: TextButton.icon(
                  onPressed: () => c.retryMessage(m),
                  icon: const Icon(Icons.refresh, size: 16),
                  label: Text(
                    m.outboxPaused
                        ? 'Sending needs attention · Retry'
                        : 'Not sent · Retry',
                    style: const TextStyle(
                      fontSize: 12,
                      color: Colors.redAccent,
                    ),
                  ),
                ),
              ),
            if (m.status == 'queued' && !m.outboxPaused)
              Padding(
                padding: const EdgeInsets.only(right: 40, top: 3),
                child: Text(
                  'Queued · Sends automatically',
                  key: Key('message-queued-${m.id}'),
                  style: TextStyle(
                    fontSize: 11,
                    color: ChatColors.of(context).muted,
                  ),
                ),
              ),
            if ((m.status == 'failed' || m.outboxPaused) &&
                m.lastErrorText != null)
              Padding(
                padding: const EdgeInsets.only(right: 40, top: 2),
                child: Text(
                  m.lastErrorText!,
                  key: Key('message-send-error-${m.id}'),
                  style: const TextStyle(fontSize: 11, color: Colors.redAccent),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ChatPattern extends CustomPainter {
  const _ChatPattern();
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xFFB7CCCA).withValues(alpha: .25)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    for (double x = 25; x < size.width; x += 85) {
      for (double y = 25; y < size.height; y += 85) {
        canvas.drawCircle(Offset(x, y), 3, paint);
        canvas.drawLine(Offset(x + 29, y + 32), Offset(x + 35, y + 38), paint);
        canvas.drawLine(Offset(x + 35, y + 32), Offset(x + 29, y + 38), paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _EditMessageDialog extends StatefulWidget {
  const _EditMessageDialog({required this.message});
  final ChatMessage message;
  @override
  State<_EditMessageDialog> createState() => _EditMessageDialogState();
}

class _EditMessageDialogState extends State<_EditMessageDialog> {
  late final TextEditingController _field = TextEditingController(
    text: widget.message.text,
  );
  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Edit message'),
    content: SizedBox(
      width: 430,
      child: TextField(
        key: const Key('edit-message-text'),
        controller: _field,
        autofocus: true,
        minLines: 2,
        maxLines: 7,
        maxLength: 10000,
        decoration: const InputDecoration(labelText: 'Message'),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        key: const Key('save-message-edit'),
        onPressed: () {
          if (_field.text.trim().isNotEmpty) {
            Navigator.pop(context, _field.text.trim());
          }
        },
        child: const Text('Save changes'),
      ),
    ],
  );
}
