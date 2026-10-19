import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'chat_flows_test.dart' show mount;
import 'fake_chat_controller.dart';

void main() {
  testWidgets(
    'workspace inspector enables capture and observes state without rebuild feedback',
    (tester) async {
      final controller = FakeChatController();
      await mount(tester, controller);
      await tester.tap(find.byTooltip('Workspace menu'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Flutter inspector'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('inspector-enabled')));
      await tester.pumpAndSettle();
      expect(controller.debugInspector.enabled, true);
      await tester.tap(find.byKey(const Key('inspector-close')));
      await tester.pumpAndSettle();
      controller.clearError();
      await tester.pumpAndSettle();
      final before = controller.debugInspector.snapshot();
      expect(
        (before['events']! as List).where(
          (dynamic e) => e['category'] == 'state',
        ),
        isNotEmpty,
      );
      expect((before['builds']! as Map)['ChatShell'], greaterThan(0));
      await tester.tap(find.byKey(const Key('sync-diagnostics')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('open-flutter-inspector')));
      await tester.pumpAndSettle();
      final buildCount =
          (controller.debugInspector.snapshot()['builds']! as Map)['ChatApp'];
      await tester.tap(find.byKey(const Key('inspector-refresh')));
      await tester.pumpAndSettle();
      expect(
        (controller.debugInspector.snapshot()['builds']! as Map)['ChatApp'],
        buildCount,
      );
      expect(tester.takeException(), isNull);
      controller.debugInspector.setEnabled(false);
      await tester.pumpAndSettle();
    },
  );
}
