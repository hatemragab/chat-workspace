import 'dart:async';

import 'package:chat_workspace/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'Retry updates the storage lease without returning a Future from setState',
    (tester) async {
      final retry = Completer<bool>();
      var attempts = 0;
      await tester.pumpWidget(
        StorageGate(
          acquireLease: () {
            attempts++;
            return attempts == 1 ? Future<bool>.value(false) : retry.future;
          },
        ),
      );
      await tester.pumpAndSettle();
      final button = find.widgetWithText(FilledButton, 'Retry');
      expect(button, findsOneWidget);
      expect(attempts, 1);

      await tester.tap(button);
      expect(tester.takeException(), isNull);
      await tester.pump();
      expect(attempts, 2);
      expect(find.text('Opening your saved conversations…'), findsOneWidget);
      expect(button, findsNothing);

      retry.complete(false);
      await tester.pumpAndSettle();
      expect(button, findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
