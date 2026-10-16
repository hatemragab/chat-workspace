import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/exports.dart';
import 'auth_screen.dart';
import 'chat_shell.dart';
import 'theme.dart';

class ChatApp extends ConsumerStatefulWidget {
  const ChatApp({super.key});
  @override
  ConsumerState<ChatApp> createState() => _ChatAppState();
}

class _ChatAppState extends ConsumerState<ChatApp> {
  @override
  void initState() {
    super.initState();
    unawaited(
      Future.microtask(() => ref.read(chatControllerProvider).initialize()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(chatControllerProvider);
    return MaterialApp(
      title: 'Chat Workspace',
      debugShowCheckedModeBanner: false,
      theme: buildChatTheme(),
      home: controller.currentUser == null
          ? const AuthScreen()
          : const ChatShell(),
    );
  }
}
