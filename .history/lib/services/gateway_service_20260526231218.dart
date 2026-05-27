import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_phone_direct_caller/flutter_phone_direct_caller.dart';
import 'package:http/http.dart' as http;

import '../config.dart';

const MethodChannel _smsInboxChannel = MethodChannel('gps_gateway/sms_inbox');
const MethodChannel _smsSendChannel  = MethodChannel('gps_gateway/sms_send');

final Set<String> _processedSmsIds = <String>{};

// ══════════════════════════════════════════════════════════════════════════
//  HTTP helpers
// ══════════════════════════════════════════════════════════════════════════

Future<List<Map<String, dynamic>>> fetchPendingCommands() async {
  try {
    final res = await http.get(
      Uri.parse('$kApiBase/gateway/pending'),
      headers: {'x-api-key': kApiKey},
    ).timeout(const Duration(seconds: 10));

    if (res.statusCode == 200) {
      final list = jsonDecode(res.body) as List;
      return list.cast<Map<String, dynamic>>();
    }
  } catch (e) {
    debugPrint('[gateway] fetchPending error: $e');
  }
  return [];
}

Future<void> confirmCommand(String commandId, bool success) async {
  try {
    await http.post(
      Uri.parse('$kApiBase/gateway/confirm'),
      headers: {
        'Content-Type': 'application/json',
        'x-api-key': kApiKey,
      },
      body: jsonEncode({'command_id': commandId, 'success': success}),
    ).timeout(const Duration(seconds: 10));
  } catch (e) {
    debugPrint('[gateway] confirm error: $e');
  }
}

Future<void> reportIncomingSms(String from, String body) async {
  try {
    final res = await http.post(
      Uri.parse('$kApiBase/gateway/incoming'),
      headers: {
        'Content-Type': 'application/json',
        'x-api-key': kApiKey,
      },
      body: jsonEncode({'from': from, 'body': body}),
    ).timeout(const Duration(seconds: 10));
    debugPrint('[gateway] reported incoming SMS from $from status=${res.statusCode}');
  } catch (e) {
    debugPrint('[gateway] reportIncoming error: $e');
  }
}

// ══════════════════════════════════════════════════════════════════════════
//  SMS — envío nativo
// ══════════════════════════════════════════════════════════════════════════

Future<bool> _sendSmsNative(String to, String body) async {
  try {
    final ok = await _smsSendChannel.invokeMethod<bool>(
      'sendSms',
      {'to': to, 'body': body},
    );
    return ok ?? false;
  } catch (e) {
    debugPrint('[gateway] sendSms native error: $e');
    return false;
  }
}

// ══════════════════════════════════════════════════════════════════════════
//  SMS — lectura bandeja
// ══════════════════════════════════════════════════════════════════════════

Future<void> _readInboxAndUpload(ServiceInstance service) async {
  try {
    final result = await _smsInboxChannel.invokeMethod<List<dynamic>>(
      'readInbox',
      {'limit': 30},
    );
    if (result == null) return;

    for (final item in result) {
      if (item is! Map) continue;

      final id   = '${item['id']   ?? ''}';
      final from = '${item['from'] ?? ''}';
      final body = '${item['body'] ?? ''}';
      final date = '${item['date'] ?? ''}';

      if (id.isEmpty || body.isEmpty) continue;
      if (_processedSmsIds.contains(id)) continue;

      _processedSmsIds.add(id);
      debugPrint('[gateway] inbox SMS id=$id from=$from body=$body');

      await reportIncomingSms(from, body);
      service.invoke('sms_received', {'from': from, 'body': body, 'time': date});
    }
  } catch (e) {
    debugPrint('[gateway] readInbox error: $e');
  }
}

// ══════════════════════════════════════════════════════════════════════════
//  Helpers
// ══════════════════════════════════════════════════════════════════════════

bool _requiresCall(Map<String, dynamic> cmd) {
  final type = (cmd['type'] as String? ?? '').toLowerCase();
  final body = (cmd['body'] as String? ?? '').toLowerCase();
  return type == 'call' || type == 'monitor' || body.startsWith('monitor');
}

Future<bool> _callDirect(String phoneNumber) async {
  try {
    final result = await FlutterPhoneDirectCaller.callNumber(phoneNumber);
    debugPrint('[gateway] direct call to $phoneNumber: $result');
    return result ?? false;
  } catch (e) {
    debugPrint('[gateway] direct call error: $e');
    return false;
  }
}

// ══════════════════════════════════════════════════════════════════════════
//  Entry point del background service
// ══════════════════════════════════════════════════════════════════════════

@pragma('vm:entry-point')
void onStart(ServiceInstance service) async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();

  debugPrint('[gateway] background service started');

  // Leer bandeja inmediatamente al arrancar
  await _readInboxAndUpload(service);

  // Plan B: leer bandeja cada 10 segundos
  Timer.periodic(const Duration(seconds: 10), (_) async {
    await _readInboxAndUpload(service);
  });

  // Polling de comandos pendientes
  Timer.periodic(Duration(seconds: kPollSecs), (_) async {
    final commands = await fetchPendingCommands();

    for (final cmd in commands) {
      final id        = cmd['id']   as String;
      final to        = cmd['to']   as String;
      final body      = cmd['body'] as String;
      final needsCall = _requiresCall(cmd);

      debugPrint('[gateway] sending SMS to $to: $body');

      final smsSent = await _sendSmsNative(to, body);

      if (smsSent) {
        debugPrint('[gateway] SMS sent to $to');
        service.invoke('sms_sent', {
          'to': to,
          'body': body,
          'time': DateTime.now().toIso8601String(),
        });

        if (needsCall) {
          await Future.delayed(const Duration(seconds: 3));
          final callOk = await _callDirect(to);
          debugPrint('[gateway] call result: $callOk');
          service.invoke('call_made', {
            'to': to,
            'success': callOk,
            'time': DateTime.now().toIso8601String(),
          });
          await confirmCommand(id, callOk);
        } else {
          await confirmCommand(id, true);
        }
      } else {
        debugPrint('[gateway] SMS failed to $to');
        await confirmCommand(id, false);
      }
    }
  });
}

// ══════════════════════════════════════════════════════════════════════════
//  Inicialización del servicio
// ══════════════════════════════════════════════════════════════════════════

Future<void> initBackgroundService() async {
  final service = FlutterBackgroundService();

  await service.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: onStart,
      autoStart: false,
      isForegroundMode: false,
      notificationChannelId: 'gps_gateway',
      initialNotificationTitle: 'GPS Gateway',
      initialNotificationContent: 'Iniciando...',
      foregroundServiceNotificationId: 888,
    ),
    iosConfiguration: IosConfiguration(autoStart: false),
  );
}