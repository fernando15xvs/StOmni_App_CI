import '../../support/test_operation_policy.dart';
import 'package:core_logic/core_logic.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const validator = ValidateSaleUseCase();
  test('valida importes y devuelve detalles listos para persistir', () {
    final result = validator.execute(_command());
    expect(result.subtotal, 20);
    expect(result.lines.single.baseQuantity, 2);
    expect(() => result.lines.clear(), throwsUnsupportedError);
  });
  test(
    'rechaza números no finitos, total inconsistente y pagos incompletos',
    () {
      for (final command in [
        _command(total: double.nan),
        _command(total: double.infinity),
        _command(total: -1),
        _command(total: 19),
        _command(paid: 19),
        _command(lineSubtotal: double.nan),
        _command(paid: double.infinity),
      ]) {
        expect(() => validator.execute(command), throwsStateError);
      }
    },
  );
  test('venta a crédito exige que los pagos coincidan con el abono', () {
    expect(
      validator.execute(_command(credit: true, deposit: 5, paid: 5)).subtotal,
      20,
    );
    expect(
      () => validator.execute(_command(credit: true, deposit: 5, paid: 4)),
      throwsStateError,
    );
    expect(
      validator.execute(_command(credit: true, deposit: 0, paid: 0)).subtotal,
      20,
    );
  });
  test(
    'policy fiscal sustituible y validación previa a efectos de datos',
    () async {
      final context = _Context();
      final processing = _Processing();
      final useCase = ProcesarVentaUseCase(
        authorizer: TestOperationAuthorizer(user: 'user-1'),
        businessPolicy: ConfiguredBusinessSalePolicy(TestBusinessProfiles()),
        context: context,
        processing: processing,
        fiscalPolicy: const _ReceiptPolicy(),
      );
      await expectLater(
        useCase.ejecutarCommand(_command(type: 'rechazado')),
        throwsStateError,
      );
      expect(context.calls, 0);
      expect(processing.request, isNull);
      await useCase.ejecutarCommand(_command(type: 'receipt'));
      expect(processing.request!.tipoComprobante, 'receipt');
    },
  );
  test('no persiste si cambia la sesión al resolver el cliente', () async {
    final context = _Context()..changeUser = true;
    final processing = _Processing();
    final useCase = ProcesarVentaUseCase(
      authorizer: TestOperationAuthorizer(user: 'user-1'),
      businessPolicy: ConfiguredBusinessSalePolicy(TestBusinessProfiles()),
      context: context,
      processing: processing,
      fiscalPolicy: const InternalTicketFiscalPolicy(),
    );
    await expectLater(useCase.ejecutarCommand(_command()), throwsStateError);
    expect(processing.request, isNull);
  });
  test(
    'presentaciones configuradas bloquean emisión electrónica antes de efectos',
    () {
      final context = _Context();
      final useCase = ProcesarVentaUseCase(
        authorizer: TestOperationAuthorizer(user: 'user-1'),
        businessPolicy: ConfiguredBusinessSalePolicy(TestBusinessProfiles()),
        context: context,
        processing: _Processing(),
        fiscalPolicy: const _ElectronicPolicy(),
      );
      final base = CommercialPresentation.base(
        code: 'botella',
        singularLabel: 'Botella',
        pluralLabel: 'Botellas',
      );
      final profile = ProductUnitProfile(baseUnit: base, presentations: [base]);
      final product = SaleProductSnapshot(
        name: 'Agua',
        unitConfiguration: ProductUnitConfiguration(
          revision: 1,
          profile: profile,
        ),
      );
      final command = ProcesarVentaCommand(
        requestId: 'configured-electronic',
        fecha: DateTime(2026, 9, 4),
        tipoComprobante: 'electronic',
        customer: const SaleCustomer(ruc: '', nombre: 'Cliente', direccion: ''),
        esCredito: false,
        totalAPagar: 20,
        montoAbono: 0,
        subtotalBruto: 20,
        payments: const [SalePayment(metodo: 'Efectivo', monto: 20)],
        cart: SaleCart([
          SaleCartLine(
            productId: 1,
            warehouseId: 1,
            product: product,
            quantity: 2,
            subtotal: 20,
            commercialUnit: 'botella',
            commercialUnitPrice: 10,
            baseUnitPrice: 10,
            recordedBaseQuantity: 2,
          ),
        ]),
      );
      expect(() => useCase.validateCommand(command), throwsStateError);
      expect(context.calls, 0);
    },
  );
}

ProcesarVentaCommand _command({
  double total = 20,
  double paid = 20,
  double deposit = 0,
  double lineSubtotal = 20,
  bool credit = false,
  String type = 'ticket_interno',
}) => ProcesarVentaCommand(
  requestId: 'sale-1',
  fecha: DateTime(2026, 9, 4),
  tipoComprobante: type,
  customer: const SaleCustomer(ruc: '', nombre: 'Cliente', direccion: ''),
  esCredito: credit,
  totalAPagar: total,
  montoAbono: deposit,
  subtotalBruto: 20,
  payments: paid == 0 ? [] : [SalePayment(metodo: 'Efectivo', monto: paid)],
  cart: SaleCart([
    SaleCartLine(
      productId: 1,
      quantity: 2,
      subtotal: lineSubtotal,
      commercialUnit: 'unidad',
      warehouseId: 3,
      commercialUnitPrice: 10,
      baseUnitPrice: 10,
      recordedBaseQuantity: 2,
    ),
  ]),
);

class _ReceiptPolicy implements FiscalPolicy {
  const _ReceiptPolicy();
  @override
  FiscalDocumentType? documentFor(String code) => code == 'receipt'
      ? const FiscalDocumentType(
          code: 'receipt',
          requiresElectronicEmission: false,
          allowsOffline: false,
        )
      : null;
  @override
  String? validate(FiscalSaleDraft sale, {required DateTime now}) =>
      documentFor(sale.documentCode) == null
      ? 'Documento no habilitado.'
      : null;
}

class _ElectronicPolicy implements FiscalPolicy {
  const _ElectronicPolicy();
  @override
  FiscalDocumentType? documentFor(String code) => code == 'electronic'
      ? const FiscalDocumentType(
          code: 'electronic',
          requiresElectronicEmission: true,
          allowsOffline: false,
        )
      : null;
  @override
  String? validate(FiscalSaleDraft sale, {required DateTime now}) => null;
}

class _Context implements VentaContextGateway {
  int calls = 0;
  bool changeUser = false;
  String user = 'user-1';
  @override
  String? get currentAuthUserId => user;
  @override
  Future<bool> cajaChicaAbierta() async => true;
  @override
  Future<int?> resolverVendedorActivoId(int? vendedorId) async {
    calls++;
    return 1;
  }

  @override
  Future<int> resolverCliente({
    required String ruc,
    required String nombre,
    required String direccion,
  }) async {
    calls++;
    if (changeUser) user = 'user-2';
    return 2;
  }
}

class _Processing implements VentaProcessingGateway {
  VentaProcessingRequest? request;
  @override
  Future<VentaProcessingResult> processSale(
    VentaProcessingRequest request,
  ) async {
    this.request = request;
    return const VentaProcessingResult(
      idempotent: false,
      comprobanteId: 'sale-1',
    );
  }
}
