import '../../support/test_operation_policy.dart';
import 'package:core_logic/core_logic.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late _Context context;
  late _Processing processing;
  late SynchronizePendingSaleUseCase useCase;
  setUp(() {
    context = _Context();
    processing = _Processing();
    useCase = SynchronizePendingSaleUseCase(
      context: context,
      processSale: ProcesarVentaUseCase(
      authorizer: TestOperationAuthorizer(user: 'user-1'),
      businessPolicy: ConfiguredBusinessSalePolicy(TestBusinessProfiles()),
        context: context,
        processing: processing,
        fiscalPolicy: const InternalTicketFiscalPolicy(),
      ),
    );
  });

  test('sincroniza un ticket y conserva su clave de idempotencia', () async {
    await useCase.sincronizarVenta(_pending());
    expect(processing.request!.requestId, 'offline-1');
    expect(processing.request!.total, 20);
    expect(context.cashboxChecks, 1);
  });

  test('rechaza ventas de otro usuario sin tocar caja ni persistencia', () async {
    await expectLater(
      useCase.sincronizarVenta(_pending(authId: 'other-user')),
      throwsStateError,
    );
    expect(processing.request, isNull);
    expect(context.cashboxChecks, 0);
  });

  test('no permite sincronizar sin sesión, incluso un registro histórico', () async {
    context.userId = null;
    await expectLater(
      useCase.sincronizarVenta(_pending(authId: null)),
      throwsStateError,
    );
    expect(processing.request, isNull);
  });

  test('efectivo exige caja abierta y conserva venta si no pudo verificarse', () async {
    context.cashboxOpen = false;
    await expectLater(useCase.sincronizarVenta(_pending()), throwsStateError);
    context.cashboxOpen = true;
    context.failCashbox = true;
    await expectLater(useCase.sincronizarVenta(_pending()), throwsStateError);
    expect(processing.request, isNull);
  });

  test('pago no efectivo no consulta caja', () async {
    await useCase.sincronizarVenta(_pending(method: 'Transferencia'));
    expect(context.cashboxChecks, 0);
    expect(processing.request, isNotNull);
  });

  test('un cambio de sesión mientras consulta caja detiene la operación', () async {
    context.changeSessionAtCashbox = true;
    await expectLater(useCase.sincronizarVenta(_pending()), throwsStateError);
    expect(processing.request, isNull);
  });

  test('no sustituye una fecha inválida ni emite electrónicos desde la cola', () async {
    await expectLater(
      useCase.sincronizarVenta(_pending(date: 'invalid')),
      throwsStateError,
    );
    await expectLater(
      useCase.sincronizarVenta(_pending(document: 'factura')),
      throwsStateError,
    );
    expect(processing.request, isNull);
  });
}

PendingSale _pending({
  String? authId = 'user-1',
  String method = 'Efectivo',
  String date = '2026-08-30T10:00:00',
  String document = 'ticket_interno',
}) => PendingSaleMapper.decode({
  'request_id': 'offline-1',
  'auth_user_id': authId,
  'fecha': date,
  'tipo_comprobante': document,
  'total_a_pagar': 20.0,
  'monto_abono': 20.0,
  'subtotal_bruto': 20.0,
  'cliente': {'ruc': '', 'nombre': 'Cliente', 'direccion': ''},
  'pagos': [{'metodo': method, 'monto': 20.0}],
  'detalles': [{
    'id': 1,
    'cantidad': 2,
    'subtotal': 20.0,
    'tipo_unidad': 'unidad',
    'almacen_id': 3,
    'precio': 10.0,
    'precio_unitario_comercial': 10.0,
    'precio_unitario': 10.0,
    'piezas_reales': 2,
    'producto_data': {'nombre': 'Producto', 'tipo_venta': 'UNIDAD', 'cantidad_por_caja': 1},
  }],
});

class _Context implements VentaContextGateway {
  String? userId = 'user-1';
  bool cashboxOpen = true;
  bool failCashbox = false;
  bool changeSessionAtCashbox = false;
  int cashboxChecks = 0;

  @override
  String? get currentAuthUserId => userId;

  @override
  Future<bool> cajaChicaAbierta() async {
    cashboxChecks++;
    if (changeSessionAtCashbox) userId = 'user-2';
    if (failCashbox) throw StateError('unavailable');
    return cashboxOpen;
  }

  @override
  Future<int?> resolverVendedorActivoId(int? vendedorId) async => 9;

  @override
  Future<int> resolverCliente({
    required String ruc,
    required String nombre,
    required String direccion,
  }) async => 5;
}

class _Processing implements VentaProcessingGateway {
  VentaProcessingRequest? request;
  @override
  Future<VentaProcessingResult> processSale(VentaProcessingRequest request) async {
    this.request = request;
    return const VentaProcessingResult(idempotent: false, comprobanteId: '77');
  }
}
