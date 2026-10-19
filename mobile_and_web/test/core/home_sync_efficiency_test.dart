import 'package:chat_workspace/core/exports.dart';
import 'package:drift/native.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'review_regressions_test.dart' show delta, waitForController;
import 'sync_test.dart' show FakeApi, message, payload, testServerHealth;

class _CountingDatabase extends AppDatabase {
  _CountingDatabase() : super(NativeDatabase.memory());

  int metadataReads = 0, countReads = 0, inspections = 0;
  int outboundSubscriptions = 0;

  @override
  Future<SyncMetadataRow?> metadata() {
    metadataReads++;
    return super.metadata();
  }

  @override
  Future<Map<String, int>> rowCounts() {
    countReads++;
    return super.rowCounts();
  }

  @override
  Future<Map<String, Object?>> inspect() {
    inspections++;
    return super.inspect();
  }

  @override
  Stream<OutboundSnapshot> watchOutboundSnapshot(String senderId) {
    outboundSubscriptions++;
    return super.watchOutboundSnapshot(senderId);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('home startup, manual sync and resume avoid diagnostic table counts while explicit inspection stays fresh', () async {
    final db = _CountingDatabase();
    final inspector = DebugInspector(enabled: true);
    final api = FakeApi();
    var deltas = 0;
    api.handler = (path, _) async {
      if (path == '/presence/status') {
        return {
          'statuses': {'peer': true},
        };
      }
      deltas++;
      return delta(1, deltas == 1 ? [payload()] : []);
    };
    final controller = ChatController(
      database: db,
      api: api,
      enableRealtime: false,
      debugInspector: inspector,
    );
    try {
      await controller.debugLogin(1);
      await controller.syncNow();
      controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await waitForController(
        () =>
            (inspector.snapshot()['events'] as List<Map<String, Object?>>)
                .where(
                  (event) =>
                      event['category'] == 'action' &&
                      event['name'] == 'syncNow' &&
                      event['phase'] == 'end',
                )
                .length ==
            2,
      );
      expect(deltas, 3);
      expect(controller.selectedRoom, isNull);
      expect(db.countReads, 0);
      expect(db.inspections, 0);

      // Changes after automatic recovery must appear in the requested snapshot.
      await db.setCursor(7, 'fresh-epoch');
      await db.upsertRoom(ChatRoom.fromJson(payload(room: 'new-room', pts: 7)));
      await db.upsertMessage(message('new-message', room: 'new-room'));
      final metadataBeforeInspection = db.metadataReads;
      final snapshot = await controller.inspectDatabase();
      expect(db.inspections, 1);
      expect(db.countReads, 1);
      expect(db.metadataReads - metadataBeforeInspection, 1);
      expect(snapshot['rowCounts'], {
        'storedRoomRows': 2,
        'storedMessageRows': 1,
      });
      final diagnostics = controller.diagnostics;
      expect(diagnostics['localPts'], 7);
      expect(diagnostics['localEpoch'], 'fresh-epoch');
      expect(diagnostics['storedRoomRows'], 2);
      expect(diagnostics['storedMessageRows'], 1);
    } finally {
      await controller.logout();
      inspector.dispose();
      await db.close();
    }
  });

  test('home resume refreshes the outbox observer once and still reconciles the inbox', () async {
    final db = _CountingDatabase();
    final inspector = DebugInspector(enabled: true);
    final api = FakeApi();
    var deltas = 0;
    api.handler = (path, _) async {
      if (path == '/presence/status') {
        return {
          'statuses': {'peer': true},
        };
      }
      deltas++;
      return delta(1, deltas == 1 ? [payload()] : []);
    };
    final controller = ChatController(
      database: db,
      api: api,
      enableRealtime: false,
      debugInspector: inspector,
      healthMonitorFactory: testServerHealth,
    );
    try {
      await controller.debugLogin(1);
      await controller.outboxIdle;
      controller.didChangeAppLifecycleState(AppLifecycleState.hidden);
      final subscriptionsBeforeResume = db.outboundSubscriptions;
      inspector.clear();
      inspector.setSqliteDetailsEnabled(true);

      controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await waitForController(
        () =>
            (inspector.snapshot()['events'] as List<Map<String, Object?>>).any(
              (event) =>
                  event['category'] == 'action' &&
                  event['name'] == 'syncNow' &&
                  event['phase'] == 'end',
            ),
      );
      await controller.outboxIdle;
      final outboxQueries =
          (inspector.snapshot()['events'] as List<Map<String, Object?>>).where((
            event,
          ) {
            if (event['category'] != 'drift' ||
                event['name'] != 'query.select' ||
                event['phase'] != 'end') {
              return false;
            }
            final data = event['data'] as Map<String, Object?>;
            final sqlite = data['sqlite'] as Map<String, Object?>?;
            final statement = sqlite?['statement'] as String?;
            return statement?.startsWith('WITH counts AS') ?? false;
          });
      expect(db.outboundSubscriptions - subscriptionsBeforeResume, 1);
      // Drift can reuse the unchanged cached result during re-subscription.
      expect(outboxQueries.length, lessThanOrEqualTo(1));
      expect(deltas, 2);
      expect(controller.selectedRoom, isNull);
      expect(controller.connectionStatus, 'Connected');
    } finally {
      await controller.logout();
      inspector.dispose();
      await db.close();
    }
  });
}
