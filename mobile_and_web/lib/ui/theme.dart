import 'package:flutter/material.dart';
import 'package:v_chat_input_ui/v_chat_input_ui.dart';

abstract final class ChatColors {
  static const primary = Color(0xFF2477C5);
  static const ink = Color(0xFF203447);
  static const muted = Color(0xFF728596);
  static const border = Color(0xFFE6EDF2);
  static const canvas = Color(0xFFF4F7FA);
  static const chatCanvas = Color(0xFFEDF3F2);
  static const online = Color(0xFF24A67A);
}

ThemeData buildChatTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: ChatColors.primary,
    surface: Colors.white,
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: ChatColors.canvas,
    fontFamily: 'Arial',
    textTheme: const TextTheme(
      bodyLarge: TextStyle(fontSize: 16, color: ChatColors.ink),
      bodyMedium: TextStyle(fontSize: 14, color: ChatColors.ink),
      titleLarge: TextStyle(fontSize: 21, fontWeight: FontWeight.w700),
      titleMedium: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
    ),
    dividerTheme: const DividerThemeData(color: ChatColors.border, space: 1),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: ChatColors.canvas,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: ChatColors.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: ChatColors.border),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(48, 48),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    ),
    extensions: [
      VInputTheme.light(
        containerDecoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: ChatColors.border),
        ),
        sendBtn: const CircleAvatar(
          radius: 22,
          backgroundColor: ChatColors.primary,
          child: Icon(Icons.send_rounded, size: 22, color: Colors.white),
        ),
        textFieldTextStyle: const TextStyle(
          fontSize: 15,
          color: ChatColors.ink,
        ),
      ).copyWith(
        fileIcon: const Icon(Icons.attach_file, color: ChatColors.muted),
        emojiIcon: const Icon(
          Icons.emoji_emotions_outlined,
          color: ChatColors.muted,
        ),
      ),
    ],
  );
}

class ChatAvatar extends StatelessWidget {
  const ChatAvatar({
    super.key,
    required this.name,
    this.id = '',
    this.url,
    this.radius = 24,
    this.online = false,
    this.group = false,
  });
  final String name;
  final String id;
  final String? url;
  final double radius;
  final bool online;
  final bool group;
  @override
  Widget build(BuildContext context) {
    const colors = [
      Color(0xFF73A6C5),
      Color(0xFF8A91BF),
      Color(0xFF67AE9B),
      Color(0xFFD7A06F),
      Color(0xFFB48BA8),
    ];
    final color = colors[id.codeUnits.fold(0, (a, b) => a + b) % colors.length];
    final parts = name
        .trim()
        .split(RegExp(r'\s+'))
        .where((s) => s.isNotEmpty)
        .toList();
    final initials = parts.isEmpty
        ? '?'
        : parts.take(2).map((s) => s.characters.first).join().toUpperCase();
    return Semantics(
      label: online ? '$name, online' : name,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          CircleAvatar(
            radius: radius,
            backgroundColor: color,
            foregroundImage: url == null || url!.isEmpty
                ? null
                : NetworkImage(url!),
            child: group
                ? Icon(Icons.group_outlined, color: Colors.white, size: radius)
                : Text(
                    initials,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: radius * .65,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
          ),
          if (online)
            Positioned(
              right: 0,
              bottom: 0,
              child: Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(
                  color: ChatColors.online,
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 2),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class BrandMark extends StatelessWidget {
  const BrandMark({super.key, this.large = false});
  final bool large;
  @override
  Widget build(BuildContext context) => Container(
    width: large ? 64 : 38,
    height: large ? 64 : 38,
    decoration: BoxDecoration(
      color: ChatColors.primary,
      borderRadius: BorderRadius.circular(large ? 21 : 13),
    ),
    child: Icon(
      Icons.near_me_rounded,
      color: Colors.white,
      size: large ? 34 : 21,
    ),
  );
}
