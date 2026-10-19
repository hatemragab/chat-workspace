import 'dart:typed_data';

import 'package:chat_workspace/core/chat_api.dart';
import 'package:chat_workspace/ui/private_media.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _RetryMediaApi extends ChatApi {
  int requests = 0;

  @override
  Future<Uint8List> imageBytes(String path) async {
    if (++requests == 1) throw const ChatApiException('Offline');
    return Uint8List.fromList([1, 2, 3]);
  }
}

void main() {
  testWidgets(
    'Retry image download reloads failed bytes without a setState exception',
    (tester) async {
      final api = _RetryMediaApi();
      addTearDown(() => api.dio.close());
      const path = '/public/uploads/synthetic.png';
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PrivateMedia(
              api: api,
              paths: const [path],
              builder: (bytes) => Text(
                bytes[path]?.isNotEmpty == true
                    ? 'Image ready'
                    : 'Image unavailable',
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Image unavailable'), findsOneWidget);
      expect(api.requests, 1);

      await tester.tap(find.text('Retry image download'));
      expect(tester.takeException(), isNull);
      await tester.pumpAndSettle();
      expect(api.requests, 2);
      expect(find.text('Image ready'), findsOneWidget);
      expect(find.text('Retry image download'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
