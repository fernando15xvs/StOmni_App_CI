import 'package:core_logic/core_logic.dart';
import 'package:flutter_test/flutter_test.dart';
import '../../support/test_operation_policy.dart';

void main() {
  test('sin permiso no resuelve clientes ni persiste', () async {
    final data = _Data();
    final useCase = _useCase(data, TestOperationAuthorizer(role: 'sin_rol'), TestBusinessProfiles());
    await expectLater(useCase.ejecutarCommand(_command()), throwsA(isA<UserFacingException>()));
    expect(data.effects, 0);
  });

  test('capacidades bloquean venta online antes de cualquier efecto', () async {
    final data = _Data();
    final profiles = _noCredit();
    final useCase = _useCase(data, TestOperationAuthorizer(), profiles);
    await expectLater(useCase.ejecutarCommand(_command(credit: true)), throwsA(isA<UserFacingException>()));
    expect(data.effects, 0);
  });

  test('offline usa la misma autorización y capacidades antes de encolar', () async {
    final data = _Data();
    final authorizer = TestOperationAuthorizer(role: 'operador');
    final profiles = _noCredit();
    final queue = _Queue();
    final submit = VentaSubmissionCoordinator(
      procesarVenta: _useCase(data, authorizer, profiles),
      context: data, connectivity: _Offline(), pendingSales: queue,
      electronicDocuments: _Electronic(),
    );
    final command = _command(credit: true);
    final request = VentaSubmissionRequest(
      requestId: command.requestId, fecha: command.fecha, esCredito: true,
      totalAPagar: 20, montoAbono: 0, concepto: 'Venta', tipoComprobante: 'ticket_interno',
      subtotalBruto: 20, descuentoGlobalPorcentaje: 0, descuentoGlobalMonto: 0,
      motivoDescuento: '', cliente: command.customer, pagos: command.payments, carrito: command.cart,
    );
    await expectLater(submit.submit(request), throwsA(isA<UserFacingException>()));
    expect(authorizer.lastAllowOffline, isTrue);
    expect(profiles.lastAllowOffline, isTrue);
    expect(queue.enqueued, 0);
    expect(data.effects, 0);
    profiles.profile = TestBusinessProfiles().profile;
    final outcome = await submit.submit(request);
    expect(outcome.offlineQueued, isTrue);
    expect(queue.enqueued, 1);
  });
}

TestBusinessProfiles _noCredit() => TestBusinessProfiles()..profile = const BusinessProfile(
  businessId: '1', displayName: 'Pruebas', capabilities: BusinessCapabilities(creditSales: false),
  revision: 1, supportsCapabilitySettings: true,
);

ProcesarVentaUseCase _useCase(_Data data, TestOperationAuthorizer authorizer, TestBusinessProfiles profiles) =>
    ProcesarVentaUseCase(context: data, processing: data, authorizer: authorizer,
      businessPolicy: ConfiguredBusinessSalePolicy(profiles), fiscalPolicy: const InternalTicketFiscalPolicy());

ProcesarVentaCommand _command({bool credit = false}) => ProcesarVentaCommand(
  requestId: 'req-1', customer: const SaleCustomer(ruc: '', nombre: 'Cliente', direccion: ''),
  esCredito: credit, totalAPagar: 20, montoAbono: 0, fecha: DateTime(2026, 9, 4),
  payments: credit ? [] : const [SalePayment(metodo: 'Efectivo', monto: 20)],
  cart: SaleCart(const [SaleCartLine(productId: 1, warehouseId: 1, quantity: 2,
    subtotal: 20, commercialUnit: 'unidad', commercialUnitPrice: 10, baseUnitPrice: 10)]),
);

class _Data implements VentaContextGateway, VentaProcessingGateway {
  int effects = 0;
  @override
  String? get currentAuthUserId => 'user-1';
  @override
  Future<bool> cajaChicaAbierta() async => true;
  @override
  Future<int?> resolverVendedorActivoId(int? vendedorId) async { effects++; return 1; }
  @override
  Future<int> resolverCliente({required String ruc, required String nombre, required String direccion}) async {
    effects++; return 1;
  }
  @override
  Future<VentaProcessingResult> processSale(VentaProcessingRequest request) async {
    effects++; return const VentaProcessingResult(idempotent: false);
  }
}

class _Queue implements PendingSaleQueueGateway {
  int enqueued = 0;
  @override
  Future<void> enqueue(PendingSale sale) async { enqueued++; }
}
class _Offline implements VentaConnectivityGateway {
  @override
  Future<bool> hasConnection() async => false;
}
class _Electronic implements ElectronicSaleDocumentGateway {
  @override
  Future<ElectronicSaleDocumentResult> emitirComprobante(String comprobanteId) =>
      throw StateError('No debe emitir offline.');
}
