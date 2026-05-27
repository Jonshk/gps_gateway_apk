import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';

import '../config.dart';

const MethodChannel _controlChannel = MethodChannel('gps_gateway/control');

Future<bool> startGatewayService() async {
  try {
    final ok = await _controlChannel.invokeMethod<bool>('startService', {
      'api_base':  kApiBase,
      'api_key':   kApiKey,
      'poll_secs': kPollSecs,
    });
    debugPrint('[gateway] service started: $ok');
    return ok ?? false;
  } catch (e) {
    debugPrint('[gateway] startService error: $e');
    return false;
  }
}

Future<bool> stopGatewayService() async {
  try {
    final ok = await _controlChannel.invokeMethod<bool>('stopService');
    debugPrint('[gateway] service stopped: $ok');
    return ok ?? false;
  } catch (e) {
    debugPrint('[gateway] stopService error: $e');
    return false;
  }
}

Future<bool> isGatewayRunning() async {
  try {
    final running = await _controlChannel.invokeMethod<bool>('isRunning');
    return running ?? false;
  } catch (e) {
    debugPrint('[gateway] isRunning error: $e');
    return false;
  }
}
