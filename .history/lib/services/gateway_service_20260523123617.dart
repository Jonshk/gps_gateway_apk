import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:http/http.dart' as http;
import 'package:telephony/telephony.dart';
import '../config.dart';

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
    await http
        .post(
          Uri.parse('$kApiBase/gateway/confirm'),
          headers: {'Content-Type': 'application/json', 'x-api-key': kApiKey},
          body: jsonEncode({'command_id': commandId, 'success': success}),
        )
        .timeout(const Duration(seconds: 10));
  } catch (e) {
    debugPrint('[gateway] confirm error: $e');
  }
}

Future<void> reportIncomingSms(String from, String body) async {
  try {
    await http
        .post(
          Uri.parse('$kApiBase/gateway/incoming'),
          headers: {'Content-Type': 'application/json', 'x-api-key': kApiKey},
          body: jsonEncode({
            'from': from,
            'body': body,
            'received_at': DateTime.now().toUtc().toIso8601String(),
          }),
        )
        .timeout(const Duration(seconds: 10));
    debugPrint('[gateway] reported incoming SMS from $from');
  } catch (e) {
    debugPrint('[gateway] reportIncoming error: $e');
  }
}

@pragma('vm:entry-point')
void onStart(ServiceInstance service) async {
  final telephony = Telephony.instance;

  telephony.listenIncomingSms(
    onNewMessage: (SmsMessage message) async {
      debugPrint(
          '[gateway] SMS received from ${message.address}: ${message.body}');
      await reportIncomingSms(message.address ?? '', message.body ?? '');
      service.invoke('sms_received', {
        'from': message.address,
        'body': message.body,
        'time': DateTime.now().toIso8601String(),
      });
    },
    listenInBackground: false,
  );

  Timer.periodic(Duration(seconds: kPollSecs), (_) async {
    final commands = await fetchPendingCommands();
    for (final cmd in commands) {
      final id = cmd['id'] as String;
      final to = cmd['to'] as String;
      final body = cmd['body'] as String;
      debugPrint('[gateway] sending SMS to $to: $body');
      try {
        await telephony.sendSms(to: to, message: body);
        await confirmCommand(id, true);
        service.invoke('sms_sent', {
          'to': to,
          'body': body,
          'time': DateTime.now().toIso8601String(),
        });
      } catch (e) {
        debugPrint('[gateway] send error: $e');
        await confirmCommand(id, false);
      }
    }
  });

  if (service is AndroidServiceInstance) {
    service.setForegroundNotificationInfo(
      title: 'GPS Gateway activo',
      content: 'Escuchando comandos y SMS...',
    );
  }
}

Future<void> initBackgroundService() async {
  final service = FlutterBackgroundService();
  await service.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: onStart,
      autoStart: false,
      isForegroundMode: true,
      notificationChannelId: 'gps_gateway',
      initialNotificationTitle: 'GPS Gateway',
      initialNotificationContent: 'Iniciando...',
      foregroundServiceNotificationId: 888,
    ),
    iosConfiguration: IosConfiguration(autoStart: false),
  );
}
