import 'package:core_logic/features/ventas/data/quotation_sale_cart_mapper.dart';
import 'package:core_logic/utils/stock_utils.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Map<String, dynamic> currentProduct() => {
    'id': 9,
    'codigo': 'BOT-1',
    'nombre': 'Agua',
    'tipo_venta': 'CAJA_UNIDADES',
    'cantidad_por_caja': 24,
    'precio_unidad': 2.0,
    'precio_caja': 1.8,
    'activo': true,
  };

  Map<String, dynamic> configuredDetail() => {
    'id': 41,
    'producto_id': 9,
    'cantidad': 12,
    'piezas_reales': 12,
    'precio_unitario': 2.0,
    'precio_unitario_comercial': 2.0,
    'subtotal': 24.0,
    'almacen_id': 3,
    'tipo_unidad': 'unidad',
    'tipo_venta_snapshot': 'CAJA_UNIDADES',
    'pcs_snapshot': 24,
    'unidad_base_snapshot': 'Botella',
    'producto_nombre_snapshot': 'Agua',
    'productos': currentProduct(),
    'presentation_snapshot': {
      'schema_version': 1,
      'code': 'pack_6',
      'singular': 'Pack',
      'plural': 'Packs',
      'factor': 6,
      'quantity': 2,
      'commercial_price': 12.0,
      'base_code': 'botella',
      'base_label': 'Botella',
      'revision': 4,
      'profile': {
        'schema_version': 2,
        'base_code': 'botella',
        'presentations': [
          {
            'code': 'botella',
            'singular': 'Botella',
            'plural': 'Botellas',
            'factor': 1,
            'fractional': false,
            'precision': 0,
          },
          {
            'code': 'pack_6',
            'singular': 'Pack',
            'plural': 'Packs',
            'factor': 6,
            'fractional': false,
            'precision': 0,
          },
        ],
      },
    },
  };

  test('restaura cantidad y presentación configurables desde snapshot', () {
    final quotation = <String, dynamic>{
      'detalle_cotizaciones': [configuredDetail()],
    };

    final cart = QuotationSaleCartMapper.decode(quotation);
    final line = cart.lines.single;

    expect(line.quantity, 2);
    expect(line.commercialUnit, 'pack_6');
    expect(line.commercialUnitPrice, 12);
    expect(line.recordedBaseQuantity, 12);
    expect(line.product.unitConfiguration?.revision, 4);
    expect(
      line.product.unitConfiguration?.profile.find('pack_6')?.baseQuantity,
      6,
    );
  });

  test('proyección visual muestra cantidad y etiqueta comerciales', () {
    final display = QuotationSaleCartMapper.restoreForDisplay(
      configuredDetail(),
    );

    expect(display['cantidad'], 2);
    expect(display['precio_unitario_comercial'], 12.0);
    expect(display['commercial_unit_code_snapshot'], 'pack_6');
    expect(display['display_unit_label'], 'Packs');
    expect(
      StockUtils.etiquetaUnidadComercial(
        display['tipo_unidad'] as String,
        cantidad: 2,
      ),
      'Packs',
    );
    expect(display['piezas_reales'], 12);
    expect(display['precio_unitario'], 2.0);
  });

  test(
    'proyección documental usa precio comercial sin alterar piezas reales',
    () {
      final document = QuotationSaleCartMapper.documentDetail(
        configuredDetail(),
      );

      expect(document['cantidad'], 2);
      expect(document['precio_unitario'], 12.0);
      expect(document['piezas_reales'], 12);
      expect(document['producto_nombre_snapshot'], 'Agua · Packs');
      expect(document['subtotal'], 24.0);
    },
  );

  test('payload de conversión conserva revisión y snapshot comercial', () {
    final payload = QuotationSaleCartMapper.processingDetail(
      configuredDetail(),
    );

    expect(payload['cantidad'], 2);
    expect(payload['piezas_reales'], 12);
    expect(payload['tipo_unidad'], 'pack_6');
    expect(payload['precio_unitario_comercial'], 12.0);
    expect(payload['unit_profile_revision'], 4);
    expect(payload['commercial_unit_label'], 'Pack');
    expect(payload['unidadLabel'], 'Botella');
  });

  test(
    'cotización legacy conserva fallback de piezas y unidad normalizada',
    () {
      final payload = QuotationSaleCartMapper.processingDetail({
        'producto_id': 5,
        'cantidad': 3,
        'subtotal': 30.0,
        'precio_unitario_comercial': 10.0,
        'almacen_id': 2,
        'tipo_unidad': 'UNIDADES',
        'unidad_base_snapshot': 'Unidad',
      });

      expect(payload['cantidad'], 3);
      expect(payload['piezas_reales'], 3);
      expect(payload['tipo_unidad'], 'unidad');
      expect(payload['precio_unitario'], 10.0);
    },
  );

  test(
    'snapshot configurable sin perfil se rechaza al reconstruir carrito',
    () {
      final quotation = <String, dynamic>{
        'detalle_cotizaciones': [
          {
            'id': 1,
            'producto_id': 9,
            'cantidad': 6,
            'piezas_reales': 6,
            'subtotal': 12.0,
            'almacen_id': 3,
            'productos': currentProduct(),
            'presentation_snapshot': {
              'schema_version': 1,
              'code': 'pack_6',
              'singular': 'Pack',
              'base_label': 'Botella',
              'quantity': 1,
              'commercial_price': 12.0,
              'revision': 4,
            },
          },
        ],
      };

      expect(
        () => QuotationSaleCartMapper.decode(quotation),
        throwsA(isA<FormatException>()),
      );
    },
  );
}
