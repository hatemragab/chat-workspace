import 'package:chat_workspace/core/exports.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'review_regressions_test.dart' show delta, session;
import 'sync_test.dart' show FakeApi;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('traffic identity follows installed sessions before startup requests and clears on logout', () async {
    SharedPreferences.setMockInitialValues({});
    final db = AppDatabase(NativeDatabase.memory());
    final api = FakeApi();
    final actors = <String?>[];
    var account = 'me';
    api.authHandler = (_) async => session(account);
    api.handler = (path, _) async {
      if (path == '/rooms/delta') {
        actors.add(api.trafficLogger.userId);
        return delta(0, []);
      }
      return {'statuses': <String, bool>{}};
    };
    final controller = ChatController(
      database: db,
      api: api,
      enableRealtime: false,
    );
    try {
      await controller.debugLogin(1);
      expect(api.trafficLogger.userId, 'me');
      account = 'other';
      await controller.debugLogin(2);
      expect(api.trafficLogger.userId, 'other');
      expect(actors, ['me', 'other']);
      await controller.logout();
      expect(api.trafficLogger.userId, isNull);
      expect(api.hasSessionToken, false);
    } finally {
      await controller.logout();
      await db.close();
    }
  });
}
