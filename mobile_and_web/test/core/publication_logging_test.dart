import 'package:chat_workspace/core/exports.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'sync_test.dart' show FakeApi, payload;

class _CommitFailureDatabase extends AppDatabase {
  _CommitFailureDatabase() : super(NativeDatabase.memory());
  bool failCommit = false;
  @override
  Future<void> setCursor(int pts, String epoch) {
    if (failCommit) throw StateError('synthetic commit failure');
    return super.setCursor(pts, epoch);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('publication stages distinguish commit, duplicate and rollback without message contents', () async {
    final inspector = DebugInspector(enabled: true)
      ..updateContext(userId: 'me', sessionGeneration: 1);
    final db = _CommitFailureDatabase();
    await db.initializeSession('me');
    await db.setCursor(0, 'epoch');
    final sync = InboxSyncService(
      database: db,
      api: FakeApi(),
      userId: 'me',
      isCurrentSession: () => true,
      inspector: inspector,
    );
    final event = {'pts': 1, 'epoch': 'epoch', 'room': payload(pts: 1)};
    await sync.receivePublication(event);
    await sync.receivePublication(event);
    db.failCommit = true;
    await expectLater(
      sync.receivePublication({
        'pts': 2,
        'epoch': 'epoch',
        'room': payload(pts: 2),
      }),
      throwsStateError,
    );
    final events = (inspector.snapshot()['events'] as List)
        .cast<Map<String, Object?>>();
    final stages = events
        .where((e) => e['category'] == 'realtime')
        .map((e) => e['data'] as Map)
        .toList();
    expect(stages.where((e) => e['stage'] == 'client_received'), hasLength(3));
    expect(stages.where((e) => e['stage'] == 'inbox_applied'), hasLength(1));
    expect(stages.where((e) => e['stage'] == 'already_covered'), hasLength(1));
    expect(stages.first['correlationKey'], 'inbox:me:epoch:1');
    expect((await db.metadata())!.localPts, 1);
    await db.close();
    inspector.dispose();
  });
}
