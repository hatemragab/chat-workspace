import 'package:flutter/material.dart';
import 'package:v_chat_bubbles/v_chat_bubbles.dart';
import 'package:v_chat_input_ui/v_chat_input_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/chat_controller.dart';
import 'private_media.dart';

abstract final class ChatColors {
  static const primary = Color(0xFF2477C5);
  static const online = Color(0xFF24A67A);
  static const seen = Color(0xFF5EADEA);
  static const delivered = Color(0xFF8696A0);

  static ChatPalette of(BuildContext context) =>
      ChatPalette(Theme.of(context).brightness);
}

@immutable
class ChatPalette {
  const ChatPalette(this.brightness);
  final Brightness brightness;
  bool get isDark => brightness == Brightness.dark;
  Color get ink => isDark ? const Color(0xFFE4EAF0) : const Color(0xFF203447);
  Color get muted => isDark ? const Color(0xFFA0AFBD) : const Color(0xFF5B6F80);
  Color get border =>
      isDark ? const Color(0xFF2C3D4C) : const Color(0xFFE6EDF2);
  Color get canvas =>
      isDark ? const Color(0xFF141E28) : const Color(0xFFF4F7FA);
  Color get surface => isDark ? const Color(0xFF1C2A38) : Colors.white;
  Color get chatCanvas =>
      isDark ? const Color(0xFF101B24) : const Color(0xFFEDF3F2);
  Color get selected =>
      isDark ? const Color(0xFF253F54) : const Color(0xFFEAF3FB);
  Color get welcome =>
      isDark ? const Color(0xFF192D3D) : const Color(0xFFE8F1F8);
  Color get reply => isDark ? const Color(0xFF22384B) : const Color(0xFFF0F6FC);
  Color get warning =>
      isDark ? const Color(0xFF3D3421) : const Color(0xFFFFF7E2);
  Color get onWarning =>
      isDark ? const Color(0xFFF2D18B) : const Color(0xFF8E691C);
}

ThemeData buildChatTheme({Brightness brightness = Brightness.dark}) {
  final colors = ChatPalette(brightness);
  final scheme = ColorScheme.fromSeed(
    seedColor: ChatColors.primary,
    brightness: brightness,
    surface: colors.surface,
  );
  final inputTheme = colors.isDark ? VInputTheme.dark() : VInputTheme.light();
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: colors.canvas,
    appBarTheme: AppBarTheme(
      backgroundColor: colors.surface,
      foregroundColor: colors.ink,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleSpacing: 16,
      titleTextStyle: TextStyle(
        fontSize: 22,
        fontWeight: FontWeight.w700,
        color: colors.ink,
      ),
      shape: Border(bottom: BorderSide(color: colors.border)),
    ),
    textTheme: TextTheme(
      bodyLarge: TextStyle(fontSize: 16, color: colors.ink),
      bodyMedium: TextStyle(fontSize: 14, color: colors.ink),
      titleLarge: const TextStyle(fontSize: 21, fontWeight: FontWeight.w700),
      titleMedium: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
    ),
    dividerTheme: DividerThemeData(color: colors.border, space: 1),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: colors.canvas,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: colors.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: colors.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: scheme.primary, width: 2),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(48, 48),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    ),
    extensions: [
      inputTheme.copyWith(
        containerDecoration: BoxDecoration(
          color: colors.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: colors.border),
        ),
        sendBtn: const CircleAvatar(
          radius: 22,
          backgroundColor: ChatColors.primary,
          child: Icon(Icons.send_rounded, size: 22, color: Colors.white),
        ),
        textFieldTextStyle: TextStyle(fontSize: 15, color: colors.ink),
        textFieldDecoration: InputDecoration(
          border: InputBorder.none,
          enabledBorder: InputBorder.none,
          filled: false,
          hintStyle: TextStyle(color: colors.muted),
        ),
        fileIcon: Icon(Icons.attach_file, color: colors.muted),
        emojiIcon: Icon(Icons.emoji_emotions_outlined, color: colors.muted),
      ),
    ],
  );
}

VBubbleTheme buildChatBubbleTheme(Brightness brightness) {
  final theme = VBubbleTheme.fromStyle(
    VBubbleStyle.telegram,
    brightness: brightness,
  );
  return theme.copyWith(
    status: theme.status.copyWith(
      sentColor: ChatColors.delivered,
      deliveredColor: ChatColors.delivered,
      readColor: ChatColors.seen,
    ),
  );
}

class ChatAvatar extends ConsumerWidget {
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
  Widget build(BuildContext context, WidgetRef ref) {
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
    final controller = ref.watch(chatControllerProvider);
    return PrivateMedia(
      showRetry: false,
      key: ValueKey('avatar:${controller.sessionGenerationId}:$url'),
      api: controller.api,
      paths: url == null ? const [] : [url!],
      builder: (bytes) => Semantics(
        label: online ? '$name, online' : name,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            CircleAvatar(
              radius: radius,
              backgroundColor: color,
              foregroundImage: bytes[url]?.isNotEmpty == true
                  ? MemoryImage(bytes[url]!)
                  : null,
              child: group
                  ? Icon(
                      Icons.group_outlined,
                      color: Colors.white,
                      size: radius,
                    )
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
                    border: Border.all(
                      color: ChatColors.of(context).surface,
                      width: 2,
                    ),
                  ),
                ),
              ),
          ],
        ),
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
