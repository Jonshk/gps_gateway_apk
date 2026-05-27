import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'services/gateway_service.dart';
import 'config.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  const AndroidNotificationChannel channel = AndroidNotificationChannel(
    'gps_gateway',
    'GPS Gateway',
    description: 'Servicio SMS Gateway para GPS Control EC',
    importance: Importance.low,
  );

  final FlutterLocalNotificationsPlugin notifications =
      FlutterLocalNotificationsPlugin();

  await notifications
      .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>()
      ?.createNotificationChannel(channel);

  SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    systemNavigationBarColor: Color(0xFF0A1628),
  ));

  await initBackgroundService();
  runApp(const GpsGatewayApp());
}

class GpsGatewayApp extends StatelessWidget {
  const GpsGatewayApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'GPS Gateway',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFF0A1628),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF00D4A0),
          surface: Color(0xFF0F1F36),
        ),
      ),
      home: const GatewayScreen(),
    );
  }
}

class GatewayScreen extends StatefulWidget {
  const GatewayScreen({super.key});
  @override
  State<GatewayScreen> createState() => _GatewayScreenState();
}

class _GatewayScreenState extends State<GatewayScreen> {
  bool _running = false;
  bool _permsOk = false;
  final List<Map<String, String>> _log = [];
  final _service = FlutterBackgroundService();

  @override
  void initState() {
    super.initState();
    _checkPerms();
    _checkRunning();
    _listenEvents();
    WakelockPlus.enable();
  }

  Future<void> _checkPerms() async {
    final sms = await Permission.sms.status;
    final phone = await Permission.phone.status;
    setState(() => _permsOk = sms.isGranted && phone.isGranted);
  }

  Future<void> _requestPerms() async {
    await [Permission.sms, Permission.phone].request();
    await _checkPerms();
  }

  Future<void> _checkRunning() async {
    final running = await _service.isRunning();
    setState(() => _running = running);
  }

  void _listenEvents() {
    _service.on('sms_sent').listen((event) {
      if (event == null) return;
      setState(() => _log.insert(0, {
            'type': 'sent',
            'text': '📤 Enviado a ${event['to']}: ${event['body']}',
            'time': _fmt(event['time'] as String? ?? ''),
          }));
    });
    _service.on('sms_received').listen((event) {
      if (event == null) return;
      setState(() => _log.insert(0, {
            'type': 'received',
            'text': '📥 De ${event['from']}: ${event['body']}',
            'time': _fmt(event['time'] as String? ?? ''),
          }));
    });
  }

  String _fmt(String iso) {
    try {
      return TimeOfDay.fromDateTime(DateTime.parse(iso)).format(context);
    } catch (_) {
      return '';
    }
  }

  Future<void> _toggle() async {
    if (_running) {
      _service.invoke('stopService');
      setState(() => _running = false);
      _addLog('system', '⏹ Servicio detenido');
    } else {
      if (!_permsOk) {
        await _requestPerms();
        return;
      }
      await _service.startService();
      setState(() => _running = true);
      _addLog('system', '▶ Servicio iniciado');
    }
  }

  void _addLog(String type, String text) {
    setState(() => _log.insert(0, {
          'type': type,
          'text': text,
          'time': TimeOfDay.now().format(context),
        }));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A1628),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(children: [
            Row(children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: const Color(0xFF00D4A0).withOpacity(0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(Icons.router,
                    color: Color(0xFF00D4A0), size: 22),
              ),
              const SizedBox(width: 12),
              const Expanded(
                  child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('GPS Gateway',
                      style: TextStyle(
                          color: Color(0xFFF0F6FF),
                          fontSize: 18,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.5)),
                  Text('GPS Control EC',
                      style: TextStyle(color: Color(0x44F0F6FF), fontSize: 11)),
                ],
              )),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: (_running
                          ? const Color(0xFF00D4A0)
                          : const Color(0xFFF87171))
                      .withOpacity(0.1),
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(
                      color: (_running
                              ? const Color(0xFF00D4A0)
                              : const Color(0xFFF87171))
                          .withOpacity(0.3)),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Container(
                      width: 7,
                      height: 7,
                      decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: _running
                              ? const Color(0xFF00D4A0)
                              : const Color(0xFFF87171))),
                  const SizedBox(width: 6),
                  Text(_running ? 'Activo' : 'Detenido',
                      style: TextStyle(
                          color: _running
                              ? const Color(0xFF00D4A0)
                              : const Color(0xFFF87171),
                          fontSize: 12,
                          fontWeight: FontWeight.w600)),
                ]),
              ),
            ]),
            const SizedBox(height: 24),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: const Color(0xFF0F1F36),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.white.withOpacity(0.08)),
              ),
              child: Column(children: [
                _InfoRow(
                    label: 'Backend',
                    value: kApiBase.replaceFirst('https://', '')),
                const SizedBox(height: 8),
                _InfoRow(label: 'Poll cada', value: '${kPollSecs}s'),
                const SizedBox(height: 8),
                _InfoRow(
                  label: 'Permisos SMS',
                  value: _permsOk ? '✓ OK' : '✗ Falta',
                  valueColor: _permsOk
                      ? const Color(0xFF00D4A0)
                      : const Color(0xFFF87171),
                ),
              ]),
            ),
            const SizedBox(height: 20),
            if (!_permsOk)
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: _requestPerms,
                  icon: const Icon(Icons.security, size: 18),
                  label: const Text('Conceder permisos SMS'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFFBBF24),
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(vertical: 15),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              )
            else
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: _toggle,
                  icon:
                      Icon(_running ? Icons.stop : Icons.play_arrow, size: 20),
                  label: Text(_running ? 'Detener gateway' : 'Iniciar gateway'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _running
                        ? const Color(0xFFE8232A)
                        : const Color(0xFF00D4A0),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 15),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                    elevation: 0,
                  ),
                ),
              ),
            const SizedBox(height: 20),
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: const Color(0xFF0F1F36),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.white.withOpacity(0.08)),
                ),
                child: Column(children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('Log de actividad',
                            style: TextStyle(
                                color: Colors.white.withOpacity(0.35),
                                fontSize: 10,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 1)),
                        if (_log.isNotEmpty)
                          GestureDetector(
                              onTap: () => setState(() => _log.clear()),
                              child: Text('Limpiar',
                                  style: TextStyle(
                                      color: Colors.white.withOpacity(0.25),
                                      fontSize: 11))),
                      ],
                    ),
                  ),
                  const Divider(height: 1, color: Color(0x14FFFFFF)),
                  Expanded(
                    child: _log.isEmpty
                        ? Center(
                            child: Text('Sin actividad aún...',
                                style: TextStyle(
                                    color: Colors.white.withOpacity(0.2),
                                    fontSize: 13)))
                        : ListView.builder(
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            itemCount: _log.length,
                            itemBuilder: (_, i) {
                              final item = _log[i];
                              final color = item['type'] == 'sent'
                                  ? const Color(0xFF00D4A0)
                                  : item['type'] == 'received'
                                      ? const Color(0xFF60A5FA)
                                      : Colors.white.withOpacity(0.4);
                              return Padding(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 14, vertical: 5),
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Expanded(
                                        child: Text(item['text'] ?? '',
                                            style: TextStyle(
                                                color: color,
                                                fontSize: 12,
                                                fontFamily: 'monospace'))),
                                    const SizedBox(width: 8),
                                    Text(item['time'] ?? '',
                                        style: TextStyle(
                                            color:
                                                Colors.white.withOpacity(0.2),
                                            fontSize: 10)),
                                  ],
                                ),
                              );
                            }),
                  ),
                ]),
              ),
            ),
            const SizedBox(height: 12),
            Text(
                'Mantén la app abierta o en segundo plano.\nNo optimices batería para esta app.',
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: Colors.white.withOpacity(0.2),
                    fontSize: 10,
                    height: 1.6)),
          ]),
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final String label, value;
  final Color? valueColor;
  const _InfoRow({required this.label, required this.value, this.valueColor});

  @override
  Widget build(BuildContext context) => Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label,
              style: TextStyle(
                  color: Colors.white.withOpacity(0.4), fontSize: 12)),
          Text(value,
              style: TextStyle(
                  color: valueColor ?? const Color(0xFFF0F6FF),
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  fontFamily: 'monospace')),
        ],
      );
}
