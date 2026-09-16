import 'package:core_logic/core_logic.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:onesignal_flutter/onesignal_flutter.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../platform/notifications/notification_permission_service.dart';
import 'app_dependencies.dart';
import 'notification_navigation.dart';

bool _databaseInitialized = false;
bool _supabaseInitialized = false;
bool _preferencesInitialized = false;
bool _dateFormattingInitialized = false;
bool _oneSignalConfigured = false;

Future<void> bootstrapApp() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Renderizamos algo inmediatamente. Cualquier error de inicialización se
  // muestra dentro de Flutter en lugar de dejar una pantalla nativa vacía.
  runApp(const _BootstrapShell());
}

class _BootstrapShell extends StatefulWidget {
  const _BootstrapShell();

  @override
  State<_BootstrapShell> createState() => _BootstrapShellState();
}

class _BootstrapShellState extends State<_BootstrapShell> {
  Widget? _app;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    if (!_loading) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }

    try {
      await _initializeCriticalDependencies();
      await _initializeOptionalServices();

      if (!mounted) return;
      setState(() {
        _app = buildAppScope();
        _error = null;
        _loading = false;
      });
    } catch (e, st) {
      debugPrint('Error crítico durante bootstrap: $e');
      if (kDebugMode) debugPrintStack(stackTrace: st);

      if (!mounted) return;
      setState(() {
        _error = ErrorMapper.map(e);
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = _app;
    if (app != null) return app;

    if (_loading) {
      // Usamos ColoredBox puro para que coincida exactamente con el fondo nativo
      // de Android/iOS, evitando el parpadeo blanco (flash) que a veces
      // provoca MaterialApp antes de aplicar su tema oscuro.
      final brightness = PlatformDispatcher.instance.platformBrightness;
      return ColoredBox(
        color: brightness == Brightness.dark ? Colors.black : Colors.white,
      );
    }

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.light(),
      darkTheme: ThemeData.dark(),
      themeMode: ThemeMode.system,
      home: Scaffold(
        body: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(28),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.cloud_off_outlined, size: 52),
                  const SizedBox(height: 16),
                  const Text(
                    'No se pudo iniciar StOmni',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    _error ??
                        'Ocurrió un problema inesperado. Inténtalo nuevamente.',
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 22),
                  FilledButton.icon(
                    onPressed: _initialize,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Reintentar'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

Future<void> _initializeCriticalDependencies() async {
  if (!_databaseInitialized) {
    await initializeDatabaseForPlatform();
    _databaseInitialized = true;
  }

  const supabaseUrl = String.fromEnvironment('SUPABASE_URL');
  const supabaseAnonKey = String.fromEnvironment('SUPABASE_ANON_KEY');

  if (supabaseUrl.trim().isEmpty || supabaseAnonKey.trim().isEmpty) {
    throw const UserFacingException(
      'La configuración de conexión no está disponible en este build. '
      'Define SUPABASE_URL y SUPABASE_ANON_KEY mediante --dart-define.',
    );
  }

  if (!_supabaseInitialized) {
    await Supabase.initialize(url: supabaseUrl, anonKey: supabaseAnonKey);
    _supabaseInitialized = true;
  }

  if (!_preferencesInitialized) {
    await PreferencesService.init();
    _preferencesInitialized = true;
  }

  if (!_dateFormattingInitialized) {
    await initializeDateFormatting('es');
    _dateFormattingInitialized = true;
  }
}

Future<void> _initializeOptionalServices() async {
  // Ambas rutinas ya degradan de forma segura ante red ausente. Se mantienen
  // fuera del bloque crítico para que el arranque offline no dependa de ellas.
  await Future.wait<void>([
    AppTime.sync(),
    ConfiguracionService.cargarNegocio().then((_) {}),
  ]);

  if (_oneSignalConfigured) return;

  if (!NotificationPermissionService.isSupportedPlatform) {
    _oneSignalConfigured = true;
    return;
  }

  try {
    if (kDebugMode) {
      OneSignal.Debug.setLogLevel(OSLogLevel.verbose);
    }
    OneSignal.initialize('1db60a45-72fc-40eb-bc77-42eac4c83356');
    OneSignal.Notifications.addClickListener((event) {
      final handled = notificationNavigation.requestFromNotification(
        data: event.notification.additionalData,
        title: event.notification.title,
      );
      if (kDebugMode && handled) {
        debugPrint('OneSignal: navegación pendiente a Alerta de Stock.');
      }
    });
    // El permiso del sistema se solicita más tarde, desde Home y solamente
    // después de explicar al usuario para qué sirven las alertas.
    _oneSignalConfigured = true;
  } catch (e, st) {
    // Las notificaciones no deben impedir vender, consultar inventario o entrar
    // en modo offline. El fallo queda únicamente en logs de diagnóstico.
    debugPrint('OneSignal no pudo inicializarse: $e');
    if (kDebugMode) debugPrintStack(stackTrace: st);
  }
}
