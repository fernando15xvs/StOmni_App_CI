import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

Directory _findRepositoryRoot() {
  var current = Directory.current.absolute;
  while (true) {
    final mobile = Directory(
      '${current.path}${Platform.pathSeparator}packages${Platform.pathSeparator}mobile_app',
    );
    final core = Directory(
      '${current.path}${Platform.pathSeparator}packages${Platform.pathSeparator}core_logic',
    );
    if (mobile.existsSync() && core.existsSync()) return current;
    final parent = current.parent;
    if (parent.path == current.path) {
      throw StateError('No se pudo localizar la raiz del workspace.');
    }
    current = parent;
  }
}

File _file(Directory root, String relativePath) => File(
  '${root.path}${Platform.pathSeparator}'
  '${relativePath.replaceAll('/', Platform.pathSeparator)}',
);

void main() {
  final root = _findRepositoryRoot();
  File mobile(String path) => _file(root, 'packages/mobile_app/$path');
  File core(String path) => _file(root, 'packages/core_logic/$path');

  test('VentaPage delega checkout y no accede a infraestructura directa', () {
    final text = mobile(
      'lib/features/ventas/pages/venta_page.dart',
    ).readAsStringSync();
    expect(text, isNot(contains('supabase_flutter')));
    expect(text, isNot(contains('Supabase.instance')));
    expect(text, isNot(contains('OfflineService.')));
    expect(text, isNot(contains('FacturacionService.')));
    expect(text, contains('ventaSubmissionCoordinatorProvider'));
    expect(text, contains('VentaFormRules'));
    expect(text, contains('SaleCheckout.calculateTotals'));
    expect(text, contains('SaleCheckout.totalPaid'));
    expect(text, contains('SaleCheckout.buildPayments'));
  });

  test('reglas de checkout son framework-free', () {
    final text = core(
      'lib/features/ventas/domain/sale_checkout.dart',
    ).readAsStringSync();
    expect(text, isNot(contains('flutter')));
    expect(text, isNot(contains('riverpod')));
    expect(text, isNot(contains('../data/')));
    expect(text, contains('SaleTotals.calculate'));
    expect(text, contains('List<SalePayment> buildPayments'));
  });

  test('use case de venta depende de puertos y no de Riverpod/data', () {
    final text = core(
      'lib/features/ventas/usecases/procesar_venta_usecase.dart',
    ).readAsStringSync();
    expect(text, isNot(contains('flutter_riverpod')));
    expect(text, isNot(contains('ventaContextRepositoryProvider')));
    expect(text, isNot(contains('ventasRepositoryProvider')));
    expect(text, isNot(contains('../data/')));
    expect(text, contains('VentaContextGateway'));
    expect(text, contains('VentaProcessingGateway'));
  });

  test('coordinador de venta es framework-free y usa gateways', () {
    final text = core(
      'lib/features/ventas/application/venta_submission_coordinator.dart',
    ).readAsStringSync();
    expect(text, isNot(contains('flutter_riverpod')));
    expect(text, isNot(contains('../data/')));
    expect(text, isNot(contains('OfflineService.')));
    expect(text, isNot(contains('FacturacionService.')));
    expect(text, contains('VentaConnectivityGateway'));
    expect(text, contains('PendingSaleQueueGateway'));
    expect(text, contains('ElectronicSaleDocumentGateway'));
    expect(text, contains('if (!document.allowsOffline)'));
  });

  test('composicion de venta concentra Riverpod e infraestructura', () {
    final text = core(
      'lib/features/ventas/providers/venta_application_providers.dart',
    ).readAsStringSync();
    expect(text, contains('flutter_riverpod'));
    expect(text, contains('ventaContextRepositoryProvider'));
    expect(text, contains('ventasRepositoryProvider'));
    expect(text, contains('ventaConnectivityGatewayProvider'));
    expect(text, isNot(contains('connectivity_plus')));
    expect(text, contains('FacturacionService.emitirComprobante'));
    expect(text, contains('procesarVentaUseCaseProvider'));
    expect(text, contains('ventaSubmissionCoordinatorProvider'));
  });

  test('selección de productos delega filtro y orden al core', () {
    final page = mobile(
      'lib/features/ventas/pages/seleccion_productos_page.dart',
    ).readAsStringSync();
    final rules = core(
      'lib/features/ventas/domain/sale_product_selection.dart',
    ).readAsStringSync();
    expect(page, isNot(contains('supabase_flutter')));
    expect(page, isNot(contains('Supabase.instance')));
    expect(page, isNot(contains('supabaseProvider')));
    expect(page, contains('almacenNotifierProvider'));
    expect(page, contains('carritoProvider'));
    expect(page, contains('SaleProductSelection.filterAndSortLegacy'));
    expect(rules, isNot(contains('flutter')));
    expect(rules, isNot(contains('riverpod')));
  });

  test('CarritoController deja resumen de cantidades en core', () {
    final controller = mobile(
      'lib/features/ventas/presentation/controllers/carrito_controller.dart',
    ).readAsStringSync();
    final formatter = core(
      'lib/features/ventas/application/sale_cart_summary.dart',
    ).readAsStringSync();
    expect(controller, contains('SaleCartSummaryFormatter.format(state)'));
    expect(controller, isNot(contains('_formatQuantity')));
    expect(formatter, isNot(contains('flutter')));
    expect(formatter, isNot(contains('riverpod')));
  });

  test('VerVentaPage delega lecturas auxiliares y no usa Supabase directo', () {
    final page = mobile(
      'lib/features/ventas/pages/ver_venta_page.dart',
    ).readAsStringSync();
    final repository = core(
      'lib/features/ventas/data/venta_detalle_read_repository.dart',
    ).readAsStringSync();
    expect(page, isNot(contains('supabase_flutter')));
    expect(page, isNot(contains('Supabase.instance')));
    expect(page, isNot(contains('supabaseProvider')));
    expect(page, isNot(contains(".from('almacenes')")));
    expect(page, isNot(contains(".from('comprobantes_electronicos')")));
    expect(page, contains('ventaDetalleReadRepositoryProvider'));
    expect(repository, contains(".from('almacenes')"));
    expect(repository, contains('obtenerNombresAlmacenesHistoricos'));
    expect(repository, isNot(contains(".eq('activo', true)")));
    expect(repository, contains(".from('comprobantes_electronicos')"));
    expect(repository, contains('obtenerComprobantePorVenta'));
  });

  test('cola de ventas usa store SQLite y conserva migración histórica', () {
    final service = core(
      'lib/services/offline_service.dart',
    ).readAsStringSync();
    final store = core(
      'lib/database/pending_sale_queue_store.dart',
    ).readAsStringSync();
    final coordinator = core(
      'lib/features/ventas/application/venta_submission_coordinator.dart',
    ).readAsStringSync();
    expect(service, contains('PendingSaleQueueStore'));
    expect(
      service,
      contains("_legacyVentasPendientesKey = 'ventas_pendientes'"),
    );
    expect(service, contains('recoverInterruptedProcessing'));
    expect(service, contains("tipoComprobante != 'ticket_interno'"));
    expect(coordinator, contains('_procesarVenta.fiscalPolicy.documentFor'));
    expect(store, contains('request_id TEXT PRIMARY KEY'));
    expect(store, contains('intentos INTEGER NOT NULL DEFAULT 0'));
    expect(store, contains('ultimo_error TEXT'));
  });

  test(
    'diálogo de pendientes elimina por request_id y muestra diagnóstico',
    () {
      final dialog = mobile(
        'lib/features/balance/widgets/ventas_pendientes_dialog.dart',
      ).readAsStringSync();
      expect(dialog, contains('eliminarVentaOfflinePorRequestId'));
      expect(dialog.contains('eliminarVentaOffline(index)'), isFalse);
      expect(dialog, contains("venta['_queue_estado']"));
      expect(dialog, contains("venta['_queue_intentos']"));
      expect(dialog, contains("venta['_queue_ultimo_error']"));
      expect(dialog, contains("venta['request_id']"));
    },
  );

  test('refresh global ya no usa ValueNotifier como mecanismo de estado', () {
    final legacy = mobile('lib/home/home_notifier.dart').readAsStringSync();
    final controller = mobile(
      'lib/home/controllers/home_controller.dart',
    ).readAsStringSync();
    expect(legacy, isNot(contains("package:flutter/material.dart")));
    expect(legacy, isNot(contains('ValueNotifier<int>(')));
    expect(controller, contains('homeRefreshRevisionProvider'));
  });

  test(
    'kit documental movil usa gateway vía Riverpod y no acceso estático',
    () {
      final kit = mobile(
        'lib/core/widgets/document_form_kit.dart',
      ).readAsStringSync();
      expect(kit, isNot(contains('supabase_flutter')));
      expect(kit, isNot(contains('Supabase.instance')));
      expect(kit, isNot(contains('class ClienteService')));
      expect(kit, isNot(contains('ClienteService.')));
      expect(kit, isNot(contains('DocumentDataAccess.gateway')));
      expect(kit, contains('documentDataGatewayProvider'));
      expect(kit, contains('ConsumerStatefulWidget'));
    },
  );

  test('Dashboard obtiene resumen por repositorio y escucha Riverpod', () {
    final dashboard = mobile(
      'lib/home/widgets/dashboard_tab.dart',
    ).readAsStringSync();
    expect(dashboard, isNot(contains('supabase_flutter')));
    expect(dashboard, isNot(contains('Supabase.instance')));
    expect(dashboard, contains('dashboardRepositoryProvider'));
    expect(dashboard, contains('homeRefreshRevisionProvider'));
  });

  test('sync offline protege sesión de origen y Caja Chica', () {
    final appDependencies = mobile(
      'lib/app/app_dependencies.dart',
    ).readAsStringSync();
    final saleModels = core(
      'lib/features/ventas/domain/sale_models.dart',
    ).readAsStringSync();
    final useCase = core(
      'lib/sync/application/synchronize_pending_sale_use_case.dart',
    ).readAsStringSync();
    expect(appDependencies, contains('SynchronizePendingSaleUseCase('));
    expect(useCase, contains('PendingSaleSessionPolicy.puedeSincronizar'));
    expect(useCase, contains('sale.usaEfectivo'));
    expect(useCase, contains('cajaChicaAbierta()'));
    expect(saleModels, contains('final String? authUserId;'));
    final codec = core(
      'lib/features/ventas/data/pending_sale_mapper.dart',
    ).readAsStringSync();
    expect(codec, contains("'auth_user_id': sale.authUserId"));
  });
}
