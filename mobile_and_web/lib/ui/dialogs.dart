import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/exports.dart';
import 'theme.dart';

Future<void> showPeopleDialog(BuildContext context, {bool group = false}) =>
    showDialog<void>(
      context: context,
      builder: (_) => PeopleDialog(group: group),
    );

class PeopleDialog extends ConsumerStatefulWidget {
  const PeopleDialog({super.key, this.group = false});
  final bool group;
  @override
  ConsumerState<PeopleDialog> createState() => _PeopleDialogState();
}

class _PeopleDialogState extends ConsumerState<PeopleDialog> {
  final _title = TextEditingController();
  final _selected = <String>{};
  String _search = '';
  bool _loading = true;
  bool _submitting = false;
  String? _validation;
  @override
  void initState() {
    super.initState();
    Future.microtask(() async {
      await ref.read(chatControllerProvider).refreshUsers();
      if (mounted) setState(() => _loading = false);
    });
  }

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    if (_title.text.trim().isEmpty || _selected.isEmpty) {
      setState(
        () => _validation = 'Add a group name and choose at least one person.',
      );
      return;
    }
    setState(() {
      _submitting = true;
      _validation = null;
    });
    final c = ref.read(chatControllerProvider);
    await c.createGroup(_title.text.trim(), _selected.toList());
    if (!mounted) return;
    if (c.error == null) {
      Navigator.pop(context);
    } else {
      setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = ref.watch(chatControllerProvider);
    final users = c.users
        .where(
          (u) =>
              u.id != c.currentUser?.id &&
              u.displayName.toLowerCase().contains(_search.toLowerCase()),
        )
        .toList();
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 450, maxHeight: 650),
        child: Padding(
          padding: const EdgeInsets.all(22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.group ? 'Create a group' : 'New conversation',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  IconButton(
                    tooltip: 'Close',
                    onPressed: _submitting
                        ? null
                        : () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                widget.group
                    ? 'A shared space for your people.'
                    : 'Choose someone to say hello to.',
                style: const TextStyle(color: ChatColors.muted),
              ),
              const SizedBox(height: 22),
              if (widget.group) ...[
                TextField(
                  key: const Key('group-title'),
                  controller: _title,
                  maxLength: 100,
                  decoration: const InputDecoration(
                    labelText: 'Group name',
                    prefixIcon: Icon(Icons.group_outlined),
                  ),
                ),
                const SizedBox(height: 12),
              ],
              TextField(
                key: const Key('search-people'),
                onChanged: (value) => setState(() => _search = value),
                decoration: const InputDecoration(
                  hintText: 'Search people',
                  prefixIcon: Icon(Icons.search),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 12),
              if (_validation != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Text(
                    _validation!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              if (c.error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Text(
                    c.error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              Flexible(
                child: _loading
                    ? const Padding(
                        padding: EdgeInsets.all(36),
                        child: Center(child: CircularProgressIndicator()),
                      )
                    : users.isEmpty
                    ? const Padding(
                        padding: EdgeInsets.all(32),
                        child: Center(child: Text('No people found.')),
                      )
                    : ListView.builder(
                        shrinkWrap: true,
                        itemCount: users.length,
                        itemBuilder: (context, index) {
                          final user = users[index];
                          return ListTile(
                            key: Key('person-${user.id}'),
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 4,
                              vertical: 4,
                            ),
                            leading: ChatAvatar(
                              name: user.displayName,
                              id: user.id,
                              url: c.imageUrl(user.avatarUrl),
                              radius: 21,
                              online: c.onlineUserIds.contains(user.id),
                            ),
                            title: Text(
                              user.displayName,
                              style: const TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            subtitle: Text(
                              c.onlineUserIds.contains(user.id)
                                  ? 'Online'
                                  : 'Start a conversation',
                              style: const TextStyle(
                                fontSize: 12,
                                color: ChatColors.muted,
                              ),
                            ),
                            trailing: widget.group
                                ? Checkbox(
                                    value: _selected.contains(user.id),
                                    onChanged: _submitting
                                        ? null
                                        : (selected) => setState(() {
                                            if (selected == true) {
                                              _selected.add(user.id);
                                            } else {
                                              _selected.remove(user.id);
                                            }
                                          }),
                                  )
                                : const Icon(
                                    Icons.chevron_right,
                                    color: ChatColors.muted,
                                  ),
                            onTap: _submitting
                                ? null
                                : () async {
                                    if (widget.group) {
                                      setState(() {
                                        if (!_selected.add(user.id)) {
                                          _selected.remove(user.id);
                                        }
                                      });
                                    } else {
                                      setState(() => _submitting = true);
                                      await c.openDirect(user);
                                      if (context.mounted && c.error == null) {
                                        Navigator.pop(context);
                                      }
                                      if (mounted) {
                                        setState(() => _submitting = false);
                                      }
                                    }
                                  },
                          );
                        },
                      ),
              ),
              const SizedBox(height: 12),
              if (widget.group)
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    key: const Key('create-group-submit'),
                    onPressed: _submitting ? null : _create,
                    icon: const Icon(Icons.add),
                    label: Text(
                      _submitting
                          ? 'Creating…'
                          : 'Create group${_selected.isEmpty ? '' : ' (${_selected.length})'}',
                    ),
                  ),
                )
              else
                Row(
                  children: [
                    const Icon(Icons.group_outlined, color: ChatColors.primary),
                    const SizedBox(width: 8),
                    TextButton(
                      key: const Key('new-group'),
                      onPressed: () {
                        Navigator.pop(context);
                        showPeopleDialog(context, group: true);
                      },
                      child: const Text('Create a group instead'),
                    ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}

Future<void> showDiagnosticsDialog(BuildContext context) => showDialog<void>(
  context: context,
  builder: (_) => const DiagnosticsDialog(),
);

class DiagnosticsDialog extends ConsumerStatefulWidget {
  const DiagnosticsDialog({super.key});
  @override
  ConsumerState<DiagnosticsDialog> createState() => _DiagnosticsDialogState();
}

class _DiagnosticsDialogState extends ConsumerState<DiagnosticsDialog> {
  Map<String, Object?>? _rows;
  String? _inspectionError;
  bool _loading = true;
  @override
  void initState() {
    super.initState();
    Future.microtask(_inspect);
  }

  Future<void> _inspect() async {
    try {
      final rows = await ref.read(chatControllerProvider).inspectDatabase();
      if (mounted) {
        setState(() {
          _rows = rows;
          _loading = false;
          _inspectionError = null;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _inspectionError = 'Database inspection is unavailable.';
          _loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = ref.watch(chatControllerProvider);
    final room = c.selectedRoom;
    final data = <String, Object?>{
      ...c.diagnostics,
      'currentUser': c.currentUser?.displayName,
      'connection': c.connectionStatus,
      'loadedRooms': c.rooms.length,
      'visibleMessages': c.messages.length,
      'jumpMode': c.isJumpMode,
      if (room != null)
        'selectedRoom': {
          'id': room.roomId,
          'msgPts': room.msgPts,
          'messagesSyncedPts': room.messagesSyncedPts,
          'unreadCount': room.unreadCount,
        },
    };
    final json = const JsonEncoder.withIndent('  ').convert(data);
    return AlertDialog(
      title: const Text('Sync diagnostics'),
      content: SizedBox(
        width: 580,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Local state and synchronization counters. Authentication tokens are never shown.',
                style: TextStyle(fontSize: 13, color: ChatColors.muted),
              ),
              const SizedBox(height: 18),
              SelectableText(
                json,
                key: const Key('diagnostics-data'),
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12,
                  height: 1.55,
                ),
              ),
              const SizedBox(height: 16),
              if (_loading)
                const LinearProgressIndicator()
              else if (_inspectionError != null)
                Text(_inspectionError!)
              else
                ExpansionTile(
                  key: const Key('sqlite-inspector'),
                  title: const Text(
                    'SQLite database rows',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                  ),
                  subtitle: const Text(
                    'Read-only local snapshot',
                    style: TextStyle(fontSize: 12),
                  ),
                  tilePadding: EdgeInsets.zero,
                  children: [
                    Align(
                      alignment: Alignment.centerLeft,
                      child: SelectableText(
                        const JsonEncoder.withIndent('  ').convert(_rows),
                        key: const Key('sqlite-rows'),
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 11,
                          height: 1.5,
                        ),
                      ),
                    ),
                  ],
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton.icon(
          onPressed: () {
            Clipboard.setData(ClipboardData(text: json));
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(const SnackBar(content: Text('Diagnostics copied')));
          },
          icon: const Icon(Icons.copy, size: 17),
          label: const Text('Copy'),
        ),
        TextButton.icon(
          onPressed: () async {
            await c.syncNow();
            await _inspect();
          },
          icon: const Icon(Icons.sync, size: 17),
          label: const Text('Sync now'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    );
  }
}
