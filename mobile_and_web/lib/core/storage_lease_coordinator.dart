import 'dart:async';

/// Shares one acquisition attempt and remembers ownership for this document.
/// The browser owns the underlying lock's lifetime; retries never reacquire it.
class StorageLeaseCoordinator {
  StorageLeaseCoordinator(this._request);

  final Future<bool> Function() _request;
  Future<bool>? _pending;
  bool _held = false;

  Future<bool> acquire() {
    if (_held) return Future<bool>.value(true);
    final pending = _pending;
    if (pending != null) return pending;

    final result = Completer<bool>();
    _pending = result.future;
    unawaited(
      Future<bool>.sync(_request).then<void>(
        (acquired) {
          _held = acquired;
          _pending = null;
          result.complete(acquired);
        },
        onError: (Object error, StackTrace stack) {
          _pending = null;
          result.completeError(error, stack);
        },
      ),
    );
    return result.future;
  }
}
