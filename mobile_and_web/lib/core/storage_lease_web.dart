import 'dart:async';
import 'dart:js_interop';

import 'storage_lease_coordinator.dart';

@JS('navigator.locks')
external JSObject? get _locks;

extension type _LockManager(JSObject _) implements JSObject {
  external JSPromise<JSAny?> request(
    String name,
    JSObject options,
    JSFunction callback,
  );
}

/// The browser releases this exclusive lock on reload, tab close or crash.
/// Unsupported/denied coordination blocks storage rather than allowing writers.
Future<bool> acquireStorageLease() => _documentLease.acquire();

final _documentLease = StorageLeaseCoordinator(_requestStorageLease);

Future<bool> _requestStorageLease() async {
  final result = Completer<bool>();
  try {
    final locks = _locks;
    if (locks == null) return false;
    final held = Completer<JSAny?>();
    unawaited(
      _LockManager(locks)
          .request(
            'chat_app_db:single-active-tab',
            {'ifAvailable': true}.jsify()! as JSObject,
            ((JSAny? lock) {
              if (lock == null) {
                result.complete(false);
                return Future<JSAny?>.value(null).toJS;
              }
              result.complete(true);
              return held.future.toJS;
            }).toJS,
          )
          .toDart
          .catchError((Object _) {
            if (!result.isCompleted) result.complete(false);
            return null;
          }),
    );
  } catch (_) {
    if (!result.isCompleted) result.complete(false);
  }
  return result.future;
}
