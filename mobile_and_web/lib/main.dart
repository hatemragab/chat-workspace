import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'ui/chat_app.dart';
import 'core/storage_lease.dart';

// Keep web controls available to keyboard users and assistive technology.
SemanticsHandle? webSemanticsHandle;

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  if (kIsWeb) webSemanticsHandle = SemanticsBinding.instance.ensureSemantics();
  runApp(const StorageGate());
}

class StorageGate extends StatefulWidget {
  const StorageGate({super.key, this.acquireLease = acquireStorageLease});

  final Future<bool> Function() acquireLease;

  @override
  State<StorageGate> createState() => _StorageGateState();
}

class _StorageGateState extends State<StorageGate> {
  late Future<bool> _lease = widget.acquireLease();
  @override
  Widget build(BuildContext context) => FutureBuilder<bool>(
    future: _lease,
    builder: (context, state) => state.data == true
        ? const ProviderScope(child: ChatApp())
        : MaterialApp(
            home: Scaffold(
              body: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        state.connectionState == ConnectionState.done
                            ? 'Chat is open in another tab, or this browser cannot safely coordinate local storage. Close the other tab and retry, or use a browser with Web Locks support.'
                            : 'Opening your saved conversations…',
                      ),
                      if (state.connectionState == ConnectionState.done)
                        FilledButton(
                          onPressed: () => setState(() {
                            _lease = widget.acquireLease();
                          }),
                          child: const Text('Retry'),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
  );
}
