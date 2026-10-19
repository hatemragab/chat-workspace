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
  final _lightTheme = buildChatTheme(brightness: Brightness.light);
  final _darkTheme = buildChatTheme();
  @override
  void initState() {
    super.initState();
    unawaited(
      Future.microtask(() => ref.read(chatControllerProvider).initialize()),
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(chatControllerProvider.select((c) => c.currentUser?.id));
    final controller = ref.read(chatControllerProvider);
    controller.debugInspector.recordBuild(
      'ChatApp',
      context: controller.lastStateContext,
      notificationId: controller.lastStateNotificationId,
    );
    return MaterialApp(
      title: 'Chat Workspace',
      debugShowCheckedModeBanner: false,
      theme: _lightTheme,
      darkTheme: _darkTheme,
      themeMode: ThemeMode.dark,
      home: controller.currentUser == null
          ? const AuthScreen()
          : const ChatShell(),
    );
  }
}
