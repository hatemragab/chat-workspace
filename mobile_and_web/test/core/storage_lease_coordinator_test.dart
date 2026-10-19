import 'dart:async';

import 'package:chat_workspace/core/storage_lease_coordinator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('concurrent callers share one pending browser acquisition', () async {
    final granted = Completer<bool>();
    var requests = 0;
    final lease = StorageLeaseCoordinator(() {
      requests++;
      return granted.future;
    });

    final first = lease.acquire();
    final second = lease.acquire();
    final third = lease.acquire();
    expect(identical(first, second), true);
    expect(identical(first, third), true);
    expect(requests, 1);

    granted.complete(true);
    expect(await Future.wait([first, second, third]), [true, true, true]);
    expect(requests, 1);
  });

  test(
    'held ownership never requests the non-reentrant browser lock again',
    () async {
      var requests = 0;
      final lease = StorageLeaseCoordinator(() async => ++requests == 1);

      expect(await lease.acquire(), true);
      expect(
        await Future.wait(List.generate(10, (_) => lease.acquire())),
        everyElement(true),
      );
      expect(requests, 1);
    },
  );

  test('unavailable and failed attempts allow another acquisition', () async {
    var requests = 0;
    final lease = StorageLeaseCoordinator(() {
      requests++;
      if (requests == 1) return Future<bool>.value(false);
      if (requests == 2) throw StateError('Browser request rejected');
      return Future<bool>.value(true);
    });

    expect(await lease.acquire(), false);
    await expectLater(lease.acquire(), throwsStateError);
    expect(await lease.acquire(), true);
    expect(await lease.acquire(), true);
    expect(requests, 3);
  });
}
