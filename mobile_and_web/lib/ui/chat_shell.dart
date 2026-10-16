import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/exports.dart';
import 'dialogs.dart';
import 'messages_pane.dart';
import 'theme.dart';

class ChatShell extends ConsumerStatefulWidget {
  const ChatShell({super.key});
  @override
  ConsumerState<ChatShell> createState() => _ChatShellState();
}

class _ChatShellState extends ConsumerState<ChatShell> {
  String _search = '';
  bool _unreadOnly = false;
  @override
  Widget build(BuildContext context) {
    final c = ref.watch(chatControllerProvider);
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            if (c.error != null)
              MaterialBanner(
                content: Text(c.error!, style: const TextStyle(fontSize: 13)),
                leading: const Icon(Icons.info_outline),
                actions: [
                  TextButton(
                    onPressed: c.clearError,
                    child: const Text('Dismiss'),
                  ),
                ],
              ),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final wide = constraints.maxWidth >= 800;
                  final selected =
                      c.selectedRoom != null || c.draftPeer != null;
                  final sidebar = _sidebar(c);
                  if (!wide) {
                    return selected
                        ? const MessagesPane(compact: true)
                        : sidebar;
                  }
                  return Row(
                    children: [
                      SizedBox(
                        width: constraints.maxWidth >= 1200 ? 350 : 310,
                        child: sidebar,
                      ),
                      const VerticalDivider(width: 1),
                      Expanded(
                        child: selected
                            ? const MessagesPane()
                            : _emptyPane(context),
                      ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sidebar(ChatController c) {
    final rooms = c.rooms
        .where(
          (r) =>
              r.displayTitle.toLowerCase().contains(_search.toLowerCase()) &&
              (!_unreadOnly || r.unreadCount > 0),
        )
        .toList();
    return ColoredBox(
      color: Colors.white,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 12, 16),
            child: Row(
              children: [
                const BrandMark(),
                const SizedBox(width: 11),
                const Expanded(
                  child: Text(
                    'Workspace',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -.5,
                    ),
                  ),
                ),
                IconButton(
                  key: const Key('new-chat'),
                  tooltip: 'New conversation',
                  onPressed: () => showPeopleDialog(context),
                  icon: const Icon(
                    Icons.edit_square,
                    color: ChatColors.primary,
                  ),
                ),
                PopupMenuButton<String>(
                  tooltip: 'Workspace menu',
                  onSelected: (value) {
                    if (value == 'group') {
                      showPeopleDialog(context, group: true);
                    }
                    if (value == 'sync') c.syncNow();
                    if (value == 'diagnostics') showDiagnosticsDialog(context);
                    if (value == 'logout') c.logout();
                  },
                  itemBuilder: (_) => [
                    const PopupMenuItem(
                      value: 'group',
                      child: Text('New group'),
                    ),
                    const PopupMenuItem(value: 'sync', child: Text('Sync now')),
                    const PopupMenuItem(
                      value: 'diagnostics',
                      child: Text('Sync diagnostics'),
                    ),
                    const PopupMenuDivider(),
                    const PopupMenuItem(
                      value: 'logout',
                      child: Text('Sign out'),
                    ),
                  ],
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18),
            child: TextField(
              key: const Key('search-conversations'),
              onChanged: (s) => setState(() => _search = s),
              decoration: const InputDecoration(
                hintText: 'Search conversations',
                prefixIcon: Icon(Icons.search, size: 20),
                contentPadding: EdgeInsets.all(12),
                isDense: true,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 16, 18, 10),
            child: Wrap(
              spacing: 8,
              children: [
                ChoiceChip(
                  label: const Text('All chats'),
                  selected: !_unreadOnly,
                  onSelected: (_) => setState(() => _unreadOnly = false),
                  showCheckmark: false,
                  visualDensity: VisualDensity.compact,
                ),
                ChoiceChip(
                  label: const Text('Unread'),
                  selected: _unreadOnly,
                  onSelected: (_) => setState(() => _unreadOnly = true),
                  showCheckmark: false,
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
          ),
          Expanded(
            child: c.busy && c.rooms.isEmpty
                ? const Center(child: CircularProgressIndicator())
                : rooms.isEmpty
                ? _emptyList()
                : ListView.builder(
                    key: const Key('rooms-list'),
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    itemCount: rooms.length + (c.hasMoreRooms ? 1 : 0),
                    itemBuilder: (context, index) {
                      if (index == rooms.length) {
                        return Padding(
                          padding: const EdgeInsets.all(12),
                          child: TextButton.icon(
                            key: const Key('load-more-rooms'),
                            onPressed: c.busy ? null : c.loadMoreRooms,
                            icon: const Icon(Icons.expand_more),
                            label: const Text('Load more chats'),
                          ),
                        );
                      }
                      return _roomTile(c, rooms[index]);
                    },
                  ),
          ),
          const Divider(),
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 14, 12, 14),
            child: Row(
              children: [
                ChatAvatar(
                  name: c.currentUser!.displayName,
                  id: c.currentUser!.id,
                  radius: 19,
                  url: c.imageUrl(c.currentUser!.avatarUrl),
                  online: c.connectionStatus.toLowerCase() == 'connected',
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        c.currentUser!.displayName,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        c.connectionStatus,
                        key: const Key('connection-status'),
                        style: const TextStyle(
                          fontSize: 11,
                          color: ChatColors.muted,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  key: const Key('sync-diagnostics'),
                  tooltip: 'Sync diagnostics',
                  onPressed: () => showDiagnosticsDialog(context),
                  icon: const Icon(
                    Icons.storage_outlined,
                    size: 20,
                    color: ChatColors.muted,
                  ),
                ),
                IconButton(
                  key: const Key('switch-account'),
                  tooltip: 'Switch account',
                  onPressed: c.logout,
                  icon: const Icon(
                    Icons.logout_rounded,
                    size: 20,
                    color: ChatColors.muted,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _emptyList() => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.forum_outlined, size: 42, color: ChatColors.muted),
          const SizedBox(height: 16),
          Text(
            _search.isNotEmpty || _unreadOnly
                ? 'No matching conversations'
                : 'Your inbox is a fresh start',
            textAlign: TextAlign.center,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          const Text(
            'Find someone and say hello.',
            textAlign: TextAlign.center,
            style: TextStyle(color: ChatColors.muted),
          ),
          const SizedBox(height: 20),
          FilledButton.tonalIcon(
            onPressed: () => showPeopleDialog(context),
            icon: const Icon(Icons.add),
            label: const Text('Start a conversation'),
          ),
        ],
      ),
    ),
  );

  Widget _roomTile(ChatController c, ChatRoom room) {
    final selected = c.selectedRoom?.roomId == room.roomId;
    final last = room.lastMessage;
    final mine = last?.senderId == c.currentUser?.id;
    final preview = last == null
        ? 'No messages yet'
        : last.isDeletedForAll
        ? 'This message was deleted'
        : last.type == 'image'
        ? 'Photo${last.text.isEmpty ? '' : ': ${last.text}'}'
        : last.text;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Material(
        color: selected ? const Color(0xFFEAF3FB) : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          key: Key('room-${room.roomId}'),
          borderRadius: BorderRadius.circular(12),
          onTap: () => c.openRoom(room),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 13),
            child: Row(
              children: [
                ChatAvatar(
                  name: room.displayTitle,
                  id: room.roomId,
                  url: c.imageUrl(room.displayAvatarUrl),
                  group: room.roomType == 'group',
                  online:
                      room.peerUserId != null &&
                      c.onlineUserIds.contains(room.peerUserId),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              room.displayTitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontWeight: room.unreadCount > 0
                                    ? FontWeight.w700
                                    : FontWeight.w600,
                                fontSize: 14,
                              ),
                            ),
                          ),
                          if (room.isMuted)
                            const Padding(
                              padding: EdgeInsets.only(left: 4),
                              child: Icon(
                                Icons.notifications_off_outlined,
                                size: 13,
                                color: ChatColors.muted,
                              ),
                            ),
                          const SizedBox(width: 8),
                          Text(
                            _roomTime(room.sortTimestamp),
                            style: const TextStyle(
                              color: ChatColors.muted,
                              fontSize: 10,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 7),
                      Row(
                        children: [
                          if (mine && last != null) ...[
                            _previewStatus(last, room.roomId),
                            const SizedBox(width: 3),
                          ],
                          Expanded(
                            child: Text(
                              preview,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: ChatColors.muted,
                                fontSize: 12,
                              ),
                            ),
                          ),
                          if (room.unreadCount > 0)
                            Container(
                              key: Key('unread-${room.roomId}'),
                              constraints: const BoxConstraints(minWidth: 20),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 3,
                              ),
                              decoration: BoxDecoration(
                                color: room.isMuted
                                    ? ChatColors.muted
                                    : ChatColors.primary,
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Text(
                                '${room.unreadCount}',
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 10,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            )
                          else if (room.pinAt != null)
                            const Icon(
                              Icons.push_pin,
                              size: 14,
                              color: ChatColors.muted,
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
                PopupMenuButton<String>(
                  tooltip: 'Options for ${room.displayTitle}',
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  iconSize: 17,
                  icon: const Icon(Icons.more_vert, color: ChatColors.muted),
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
                      value: 'pin',
                      child: Text(
                        room.pinAt == null ? 'Pin chat' : 'Unpin chat',
                      ),
                    ),
                    PopupMenuItem(
                      value: 'mute',
                      child: Text(room.isMuted ? 'Unmute chat' : 'Mute chat'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _previewStatus(ChatMessage message, String roomId) {
    final sending = message.status == 'sending';
    final failed = message.status == 'failed';
    final seen = message.seenAt != null;
    final delivered = message.deliveredAt != null;
    final label = sending
        ? 'Sending message'
        : failed
        ? 'Message not sent'
        : seen
        ? 'Message seen'
        : delivered
        ? 'Message delivered'
        : 'Message sent';
    return Semantics(
      key: Key('room-preview-status-$roomId'),
      label: label,
      child: ExcludeSemantics(
        child: Icon(
          sending
              ? Icons.schedule_outlined
              : failed
              ? Icons.error_outline
              : seen || delivered
              ? Icons.done_all
              : Icons.check,
          size: 15,
          color: failed
              ? Theme.of(context).colorScheme.error
              : seen
              ? ChatColors.primary
              : ChatColors.muted,
        ),
      ),
    );
  }

  Widget _emptyPane(BuildContext context) => Container(
    color: ChatColors.chatCanvas,
    child: Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(27),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: .7),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.forum_outlined,
                size: 54,
                color: ChatColors.primary,
              ),
            ),
            const SizedBox(height: 28),
            const Text(
              'Your next conversation\nis one hello away.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.w700,
                letterSpacing: -.7,
                height: 1.25,
              ),
            ),
            const SizedBox(height: 14),
            const Text(
              'Choose a chat or start something new.',
              style: TextStyle(color: ChatColors.muted, fontSize: 15),
            ),
            const SizedBox(height: 28),
            FilledButton.icon(
              onPressed: () => showPeopleDialog(context),
              icon: const Icon(Icons.add_comment_outlined, size: 18),
              label: const Text('New conversation'),
            ),
          ],
        ),
      ),
    ),
  );
  String _roomTime(DateTime? time) {
    if (time == null) return '';
    final local = time.toLocal();
    final now = DateTime.now();
    if (local.year == now.year &&
        local.month == now.month &&
        local.day == now.day) {
      return '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
    }
    return '${local.day}/${local.month}';
  }
}
