import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../core/chat_api.dart';

/// Credentials remain in Dio's Authorization header. These bytes never enter
/// browser URL/query history, and the parent keys this widget by session.
class PrivateMedia extends StatefulWidget {
  const PrivateMedia({
    super.key,
    required this.api,
    required this.paths,
    required this.builder,
    this.showRetry = true,
  });
  final ChatApi api;
  final List<String> paths;
  final Widget Function(Map<String, Uint8List> bytes) builder;
  final bool showRetry;
  @override
  State<PrivateMedia> createState() => _PrivateMediaState();
}

class _PrivateMediaState extends State<PrivateMedia> {
  late Future<Map<String, Uint8List>> _bytes = _load();
  Future<Map<String, Uint8List>> _load() async => Map.fromEntries(
    await Future.wait(
      widget.paths.toSet().map((path) async {
        try {
          return MapEntry(path, await widget.api.imageBytes(path));
        } catch (_) {
          return MapEntry(path, Uint8List(0));
        }
      }),
    ),
  );
  @override
  void didUpdateWidget(covariant PrivateMedia oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.paths.join('|') != widget.paths.join('|') ||
        oldWidget.api != widget.api) {
      _bytes = _load();
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<Map<String, Uint8List>>(
    future: _bytes,
    builder: (context, state) {
      final data = state.data ?? const <String, Uint8List>{};
      final failed =
          state.connectionState == ConnectionState.done &&
          data.values.any((bytes) => bytes.isEmpty);
      final child = widget.builder(data);
      return failed && widget.showRetry
          ? Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                child,
                TextButton.icon(
                  onPressed: () => setState(() {
                    _bytes = _load();
                  }),
                  icon: const Icon(Icons.refresh),
                  label: const Text('Retry image download'),
                ),
              ],
            )
          : child;
    },
  );
}
