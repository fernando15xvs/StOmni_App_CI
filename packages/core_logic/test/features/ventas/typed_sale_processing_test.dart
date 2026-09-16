import '../../support/test_operation_policy.dart';
import 'package:core_logic/core_logic.dart';
import 'package:flutter_test/flutter_test.dart';

class _ContextGateway implements VentaContextGateway {
  @override
  String? get currentAuthUserId => 'auth-user';

  @override
  Future<bool> cajaChicaAbierta() async => true;

  @override
  Future<int> resolverCliente({
    required String ruc,
    required String nombre,
    required String direccion,
  }) async => 5;

  @override
  Future<int?> resolverVendedorActivoId(int? vendedorId) async => 9;
}

class _ProcessingGateway implements VentaProcessingGateway {
  VentaProcessingRequest? lastRequest;

  @override
  Future<VentaProcessingResult> processSale(
    VentaProcessingRequest request,
  ) async {
    lastRequest = request;
    return const VentaProcessingResult(idempotent: false, comprobanteId: '77');
  }
}

void main() {
  test('ProcesarVentaUseCase cruza el gateway con contratos tipados', () async {
    final processing = _ProcessingGateway();
    final useCase = ProcesarVentaUseCase(
      authorizer: TestOperationAuthorizer(user: 'auth-user'),
      businessPolicy: ConfiguredBusinessSalePolicy(TestBusinessProfiles()),
      fiscalPolicy: const InternalTicketFiscalPolicy(),
      context: _ContextGateway(),
      processing: processing,
    );

    final result = await useCase.ejecutarCommand(
      ProcesarVentaCommand(
        requestId: 'typed-boundary-1',
        customer: const SaleCustomer(
          ruc: '12345678',
          nombre: 'Cliente',
          direccion: 'Lima',
        ),
        esCredito: false,
        totalAPagar: 20,
        montoAbono: 20,
        payments: const [SalePayment(metodo: 'Efectivo', monto: 20)],
        cart: SaleCartMapper.decode([
          {
            'id': 1,
            'cantidad': 2,
            'subtotal': 20.0,
            'tipo_unidad': 'unidad',
            'almacen_id': 3,
            'precio': 10.0,
            'precio_unitario_comercial': 10.0,
            'precio_unitario': 10.0,
            'piezas_reales': 2,
            'producto_data': {
              'nombre': 'Producto',
              'tipo_venta': 'UNIDAD',
              'cantidad_por_caja': 1,
            },
          },
        ]),
        fecha: DateTime(2026, 8, 30),
        subtotalBruto: 20,
      ),
    );

    expect(result.comprobanteId, '77');
    final request = processing.lastRequest;
    expect(request, isNotNull);
    expect(request!.clienteId, 5);
    expect(request.vendedorId, 9);
    expect(request.pagos.single, isA<SalePayment>());
    expect(request.detalles.single, isA<SaleProcessingLine>());
    expect(request.detalles.single.productId, 1);
    expect(request.detalles.single.baseQuantity, 2);
    expect(request.detalles.single.subtotal, 20);
  });
}
