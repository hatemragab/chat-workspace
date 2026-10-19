import 'package:flutter/foundation.dart';

// Supply the development machine's LAN host for physical-device debug builds.
const localWifiHost = String.fromEnvironment(
  'LOCAL_WIFI_HOST',
  defaultValue: 'localhost',
);
const _defaultHost = kDebugMode && !kIsWeb ? localWifiHost : 'localhost';

const apiBaseUrl = String.fromEnvironment(
  'API_BASE_URL',
  defaultValue: 'http://$_defaultHost:3000',
);

const centrifugoUrl = String.fromEnvironment(
  'CENTRIFUGO_URL',
  defaultValue: 'ws://$_defaultHost:8000/connection/websocket',
);
