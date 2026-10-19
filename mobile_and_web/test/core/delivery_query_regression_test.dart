import 'dart:convert';

import 'package:chat_workspace/core/exports.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'review_regressions_test.dart' show delta, session, waitForController;
import 'sync_test.dart' show FakeApi, instant, message, payload;

class _DeliveryDatabase extends AppDatabase {
  _DeliveryDatabase() : super(NativeDatabase.memory());

  int targetReads = 0;

  @override
  Future<int?> receiptTarget(String roomId, {bool seen = false}) {
    targetReads++;
    return super.receiptTarget(roomId, seen: seen);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('legacy delivery does not read sequence coverage', () async {
    SharedPreferences.setMockInitialValues({});
    final db = _DeliveryDatabase();
    final incoming = message('incoming', sender: 'peer');
    final api = FakeApi()
      ..handler = (_, _) async => delta(1, [payload(last: incoming)]);
    final delivered = <Map<String, dynamic>>[];
    api.otherPostHandler = (route, body) async {
      if (route == '/rooms/delivered-batch') delivered.add(body!);
      return {'ok': true};
    };
    final controller = ChatController(
      database: db,
      api: api,
      enableRealtime: false,
    );
    try {
      await controller.debugLogin(1);
      await waitForController(() => delivered.isNotEmpty);
      expect(db.targetReads, 0);
      expect(delivered.single, {
        'roomIds': ['room'],
        'upToTimestamp': incoming.createdAt.toUtc().toIso8601String(),
      });
    } finally {
      await controller.logout();
      await db.close();
    }
  });

  test('outgoing preview still retries an older durable delivery on restart', () async {
    SharedPreferences.setMockInitialValues({
      'chat_session': jsonEncode(session('me')),
    });
    final db = _DeliveryDatabase();
    await db.initializeSession('me');
    await db.setCursor(1, 'epoch');
    await db.upsertRoom(ChatRoom.fromJson(payload(last: message('outgoing'))));
    await db.queueReceipt('room', deliveredThroughTimestamp: instant);
    final delivered = <Map<String, dynamic>>[];
    final api = FakeApi()..handler = (_, _) async => delta(1, []);
    api.otherPostHandler = (route, body) async {
      if (route == '/rooms/delivered-batch') delivered.add(body!);
      return {'ok': true};
    };
    final inspector = DebugInspector()..setEnabled(true);
    final controller = ChatController(
      database: db,
      api: api,
      debugInspector: inspector,
      enableRealtime: false,
    );
    try {
      await controller.initialize();
      await waitForController(() => delivered.isNotEmpty);
      expect(db.targetReads, 0);
      expect(delivered.single, {
        'roomIds': ['room'],
        'upToTimestamp': instant.toIso8601String(),
      });
      final events = (inspector.snapshot()['events'] as List).cast<Map>();
      expect(
        events.where((event) => event['name'] == 'receipts.delivery.queue'),
        isEmpty,
      );
      // Confirmation is asynchronous and must eventually clear the saved task.
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(await db.pendingReceiptTargets(), isEmpty);
    } finally {
      await controller.logout();
      await db.close();
      inspector.dispose();
    }
  });
}
