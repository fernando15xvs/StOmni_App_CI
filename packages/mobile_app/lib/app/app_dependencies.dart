import 'package:core_logic/core_logic.dart';
import 'package:core_logic/platform/image_selection.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/widgets/resultado_incierto_dialog.dart';
import '../features/facturacion/widgets/resultado_incierto_dialog.dart'
    as facturacion_dialog;
import '../platform/mobile_image_selection_adapter.dart';
import '../platform/connectivity/connectivity_status_service.dart';
import 'providers/sync_providers.dart';
import 'app.dart';
import 'app_connectivity_sync.dart';
import 'home_refresh_sync.dart';

/// Composition root: conecta los contratos de Core con implementaciones de
/// features sin invertir la dirección de dependencias.
Widget buildAppScope() {
  FacturacionService.configure(SupabaseFacturacionGateway());
  DocumentDataAccess.configure(
    SupabaseDocumentDataGateway(Supabase.instance.client),
  );
  ImageSelectionService.configure(MobileImageSelectionAdapter());
  configurarResultadoInciertoDialog(
    facturacion_dialog.mostrarReconciliacionResultadoIncierto,
  );

  return ProviderScope(
    overrides: [
      ventaConnectivityGatewayProvider.overrideWithValue(
        const _MobileSaleConnectivityAdapter(),
      ),
      pendingSaleSyncAdapterProvider.overrideWith(
        (ref) => SynchronizePendingSaleUseCase(
          context: ref.read(ventaContextGatewayProvider),
          processSale: ref.read(procesarVentaUseCaseProvider),
        ),
      ),
      inventorySyncAdapterProvider.overrideWith(
        (ref) => _InventorySyncAdapter(ref),
      ),
    ],
    child: const HomeRefreshSync(
      child: AppConnectivitySync(child: StOmniApp()),
    ),
  );
}

class _MobileSaleConnectivityAdapter implements VentaConnectivityGateway {
  const _MobileSaleConnectivityAdapter();

  @override
  Future<bool> hasConnection() => ConnectivityStatusService.hasInternet();
}

class _InventorySyncAdapter implements InventorySyncAdapter {
  _InventorySyncAdapter(this._ref);

  final Ref _ref;

  AlmacenRepository get _repository => _ref.read(almacenRepositoryProvider);

  @override
  Future<void> sincronizarProducto(int productoId) {
    return _repository.sincronizarProductoLocal(productoId, propagarError: true);
  }

  @override
  Future<void> sincronizarTodo({bool propagarError = false}) {
    return _repository.sincronizarConSupabase(propagarError: propagarError);
  }
}
