import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:internet_connection_checker_plus/internet_connection_checker_plus.dart';

import 'debug_inspector.dart';

enum ServerHealthStatus { unknown, checking, ready, unavailable }

/// Readiness of this API, independent of Wi-Fi, public internet and sockets.
/// Only recovery runs a timer; healthy and inactive sessions do no polling.
class ServerHealthMonitor extends ChangeNotifier {
  ServerHealthMonitor({
    required this.healthUri,
    Future<bool> Function()? probe,
    this.inspector,
    this.recoveryInterval = const Duration(seconds: 5),
    this.timeout = const Duration(seconds: 3),
  }) : _probe = probe {
    if (probe == null) {
      final checker = InternetConnection.createInstance(
        useDefaultOptions: false,
        checkInterval: recoveryInterval,
        customCheckOptions: [
          InternetCheckOption(
            uri: healthUri,
            timeout: timeout,
            responseStatusFn: (response) => response.statusCode == 200,
          ),
        ],
      );
      _probe = () => checker.hasInternetAccess;
    }
  }

  final Uri healthUri;
  final DebugInspector? inspector;
  final Duration recoveryInterval, timeout;
  late Future<bool> Function()? _probe;
  ServerHealthStatus _status = ServerHealthStatus.unknown;
  ServerHealthStatus get status => _status;
  bool get isReady => _status == ServerHealthStatus.ready;
  bool _active = true, _disposed = false, _recovering = false;
  bool _observedUnavailable = false;
  int _revision = 0;
  Timer? _timer;
  Future<bool>? _checking;

  Future<bool> check({bool force = false}) {
    if (_disposed || !_active) return Future.value(false);
    final running = _checking;
    if (running != null) return running;
    final revision = _revision;
    _setStatus(ServerHealthStatus.checking);
    late final Future<bool> checking;
    checking =
        (() async {
          var ready = false;
          try {
            ready = await _probe!().timeout(timeout);
          } catch (_) {
            // Probe failures are availability hints, never authentication failures.
          }
          if (!_disposed && _active && revision == _revision) {
            if (ready) {
              markReady();
            } else {
              markUnavailable();
            }
          }
          return ready;
        })().whenComplete(() {
          if (identical(_checking, checking)) _checking = null;
        });
    return _checking = checking;
  }

  void markReady() {
    if (_disposed) return;
    final recovered = _observedUnavailable;
    _observedUnavailable = false;
    ++_revision;
    _recovering = false;
    _timer?.cancel();
    _timer = null;
    _setStatus(ServerHealthStatus.ready, recovered: recovered);
    _updateGauges();
  }

  void markUnavailable() {
    if (_disposed) return;
    _observedUnavailable = true;
    _recovering = true;
    _setStatus(ServerHealthStatus.unavailable);
    _scheduleRecovery();
  }

  void stopRecovery() {
    _recovering = false;
    _timer?.cancel();
    _timer = null;
    _updateGauges();
  }

  void _scheduleRecovery() {
    if (_disposed || !_active || !_recovering || _timer != null) return;
    _timer = Timer(recoveryInterval, () async {
      _timer = null;
      _updateGauges();
      await check(force: true);
      _scheduleRecovery();
    });
    _updateGauges();
  }

  void setActive(bool value) {
    if (_disposed || _active == value) return;
    _active = value;
    ++_revision;
    _timer?.cancel();
    _timer = null;
    _updateGauges();
    if (value) _scheduleRecovery();
  }

  void _setStatus(ServerHealthStatus value, {bool recovered = false}) {
    if (_disposed || _status == value) return;
    final previous = _status;
    _status = value;
    inspector?.record(
      'health',
      value.name,
      data: {
        'healthStatus': value.name,
        'previousStatus': previous.name,
        'recovered': recovered,
      },
    );
    _updateGauges();
    notifyListeners();
  }

  void _updateGauges() {
    if (_disposed) return;
    inspector?.setGauges({
      'health.recoveryTimer': _timer == null ? 0 : 1,
      'health.checking': _status == ServerHealthStatus.checking ? 1 : 0,
    });
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    ++_revision;
    _timer?.cancel();
    _timer = null;
    super.dispose();
  }
}
