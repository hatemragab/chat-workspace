import 'dart:async';
import 'dart:io';

import 'package:chat_workspace/core/debug_inspector.dart';
import 'package:chat_workspace/core/server_health_monitor.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('ready logs recovery only after an observed backend outage', () async {
    final inspector = DebugInspector(enabled: true);
    final monitor = ServerHealthMonitor(
      healthUri: Uri.parse('http://localhost/health'),
      probe: () async => true,
      inspector: inspector,
    );
    try {
      monitor
          .markReady(); // A first successful send is readiness, not recovery.
      monitor.markReady(); // Repeated success emits no extra transition.
      monitor.markUnavailable();
      monitor.stopRecovery();
      expect(await monitor.check(), true);
      final ready = (inspector.snapshot()['events']! as List)
          .cast<Map<String, Object?>>()
          .where(
            (event) =>
                event['category'] == 'health' && event['name'] == 'ready',
          )
          .toList();
      expect(ready, hasLength(2));
      expect((ready.first['data']! as Map)['recovered'], false);
      expect((ready.last['data']! as Map)['recovered'], true);
      expect((ready.last['data']! as Map)['previousStatus'], 'checking');
      expect((ready.last['data']! as Map)['healthStatus'], 'ready');
    } finally {
      monitor.dispose();
      inspector.dispose();
    }
  });
  test(
    'health probe coalesces concurrent checks and never polls while ready',
    () async {
      final gate = Completer<bool>();
      var calls = 0;
      final monitor = ServerHealthMonitor(
        healthUri: Uri.parse('https://chat.test/health'),
        probe: () {
          calls++;
          return gate.future;
        },
        recoveryInterval: const Duration(milliseconds: 10),
      );
      final first = monitor.check();
      final second = monitor.check(force: true);
      expect(identical(first, second), true);
      gate.complete(true);
      expect(await first, true);
      expect(monitor.status, ServerHealthStatus.ready);
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(calls, 1);
      monitor.dispose();
    },
  );

  test(
    'only the configured health URI receives a HEAD probe without credentials',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final received = <String>[];
      server.listen((request) {
        received.add('${request.method} ${request.uri.path}');
        expect(request.headers.value('authorization'), isNull);
        request.response.statusCode = 200;
        request.response.headers.set('cache-control', 'no-store');
        request.response.close();
      });
      final monitor = ServerHealthMonitor(
        healthUri: Uri.parse('http://127.0.0.1:${server.port}/health'),
      );
      try {
        expect(
          await HttpOverrides.runWithHttpOverrides(
            monitor.check,
            _RealHttpOverrides(),
          ),
          true,
        );
        expect(received, ['HEAD /health']);
      } finally {
        monitor.dispose();
        await server.close(force: true);
      }
    },
  );

  test('unavailable recovery stops while inactive and resumes without stale writes', () async {
    var calls = 0;
    var ready = false;
    final monitor = ServerHealthMonitor(
      healthUri: Uri.parse('https://chat.test/health'),
      probe: () async {
        calls++;
        return ready;
      },
      recoveryInterval: const Duration(milliseconds: 10),
    );
    expect(await monitor.check(), false);
    monitor.setActive(false);
    final pausedCalls = calls;
    await Future<void>.delayed(const Duration(milliseconds: 35));
    expect(calls, pausedCalls);
    ready = true;
    monitor.setActive(true);
    await Future<void>.delayed(const Duration(milliseconds: 35));
    expect(monitor.isReady, true);
    monitor.dispose();
  });
}

// The diagnostic test needs widget bindings, while this health check verifies
// a real loopback HEAD request rather than the binding's synthetic HTTP 400.
class _RealHttpOverrides extends HttpOverrides {}
