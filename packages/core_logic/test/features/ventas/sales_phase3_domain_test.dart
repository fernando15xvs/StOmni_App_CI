import 'package:core_logic/core_logic.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SaleCheckout', () {
    test('calcula descuento porcentual y monto fijo', () {
      final percentage = SaleCheckout.calculateTotals(
        subtotal: 200,
        discountInput: 10,
        discountIsPercentage: true,
      );
      expect(percentage.discountAmount, 20);
      expect(percentage.discountPercentage, 10);
      expect(percentage.total, 180);

      final fixed = SaleCheckout.calculateTotals(
        subtotal: 200,
        discountInput: 30,
        discountIsPercentage: false,
      );
      expect(fixed.discountAmount, 30);
      expect(fixed.discountPercentage, 15);
      expect(fixed.total, 170);
    });

    test('suma y construye pagos de contado ignorando montos invalidos', () {
      const inputs = <SalePaymentInput>[
        SalePaymentInput(method: 'Efectivo', amount: 60),
        SalePaymentInput(method: 'Tarjeta', amount: 40),
        SalePaymentInput(method: 'Otro', amount: -5),
      ];

      expect(SaleCheckout.totalPaid(inputs), 100);
      final payments = SaleCheckout.buildPayments(
        isCredit: false,
        cashPayments: inputs,
        initialPayment: 0,
        initialPaymentMethod: 'Efectivo',
      );
      expect(payments, hasLength(2));
      expect(payments[0].metodo, 'Efectivo');
      expect(payments[1].monto, 40);
    });

    test('venta a credito solo genera el abono inicial positivo', () {
      final payments = SaleCheckout.buildPayments(
        isCredit: true,
        cashPayments: const <SalePaymentInput>[],
        initialPayment: 25.5,
        initialPaymentMethod: 'Yape',
      );
      expect(payments, hasLength(1));
      expect(payments.single.metodo, 'Yape');
      expect(payments.single.monto, 25.5);
    });
  });

  group('SaleProductSelection', () {
    final products = <Map<String, dynamic>>[
      {
        'id': 1,
        'nombre': 'Martillo',
        'codigo': 'M01',
        'codigo_barras': '111',
        'proveedor_id': 10,
      },
      {
        'id': 2,
        'nombre': 'Aceite',
        'codigo': 'A02',
        'codigo_barras': '222',
        'proveedor_id': 20,
      },
      {
        'id': 3,
        'nombre': 'Pintura',
        'codigo': 'P03',
        'codigo_barras': '333',
        'proveedor_id': 30,
      },
    ];

    test('busca por marca, codigo o nombre', () {
      final result = SaleProductSelection.filterAndSortLegacy(
        products: products,
        brandByProviderId: const {10: 'Truper', 20: 'Mobil'},
        query: 'mobil',
        selectedProductIds: const <int>{},
      );
      expect(result.map((p) => p['id']), [2]);
    });

    test('pone seleccionados primero y luego ordena por nombre', () {
      final result = SaleProductSelection.filterAndSortLegacy(
        products: products,
        brandByProviderId: const <int, String>{},
        query: '',
        selectedProductIds: const {1},
      );
      expect(result.map((p) => p['id']), [1, 2, 3]);
    });
  });

  test('SaleCartSummaryFormatter conserva unidades comerciales genericas', () {
    final cart = SaleCartMapper.decode([
      {
        'id': 1,
        'cantidad': 2,
        'subtotal': 20,
        'tipo_unidad': 'caja',
        'producto_data': {
          'tipo_venta': 'CAJA_UNIDADES',
          'cantidad_por_caja': 12,
        },
      },
      {
        'id': 2,
        'cantidad': 1.5,
        'subtotal': 15,
        'tipo_unidad': 'kg',
        'producto_data': {
          'tipo_venta': 'UNIDAD',
          'cantidad_por_caja': 1,
        },
      },
    ]);

    expect(SaleCartSummaryFormatter.format(cart), '2 cajas · 1.5 kg');
  });
}
