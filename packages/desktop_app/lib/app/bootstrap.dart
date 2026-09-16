import 'package:core_logic/core_logic.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../platform/connectivity/desktop_venta_connectivity_gateway.dart';
import 'app.dart';

Future<void> bootstrapDesktopApp() async {
  WidgetsFlutterBinding.ensureInitialized();

  try {
    await initializeDatabaseForPlatform();

    const supabaseUrl = String.fromEnvironment('SUPABASE_URL');
    const supabaseAnonKey = String.fromEnvironment('SUPABASE_ANON_KEY');

    if (supabaseUrl.trim().isEmpty || supabaseAnonKey.trim().isEmpty) {
      throw StateError(
        'Falta SUPABASE_URL o SUPABASE_ANON_KEY. '
        'Inicia desktop con --dart-define para ambas variables.',
      );
    }

    await Supabase.initialize(url: supabaseUrl, anonKey: supabaseAnonKey);
    await PreferencesService.init();

    FacturacionService.configure(SupabaseFacturacionGateway());
    DocumentDataAccess.configure(
      SupabaseDocumentDataGateway(Supabase.instance.client),
    );

    try {
      await AppTime.sync();
    } catch (_) {}

    runApp(
      ProviderScope(
        overrides: [
          ventaConnectivityGatewayProvider.overrideWithValue(
            const DesktopVentaConnectivityGateway(),
          ),
        ],
        child: const StOmniDesktopApp(),
      ),
    );
  } catch (error) {
    runApp(_DesktopBootstrapFailure(error: error.toString()));
  }
}

class _DesktopBootstrapFailure extends StatelessWidget {
  const _DesktopBootstrapFailure({required this.error});

  final String error;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 620),
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.desktop_windows_outlined, size: 54),
                  const SizedBox(height: 18),
                  const Text(
                    'StOmni Desktop no pudo iniciar',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 12),
                  Text(error, textAlign: TextAlign.center),
                  const SizedBox(height: 18),
                  const SelectableText(
                    'Ejemplo:\nflutter run -d windows '
                    '--dart-define=SUPABASE_URL=... '
                    '--dart-define=SUPABASE_ANON_KEY=...',
                    textAlign: TextAlign.center,
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
