import 'package:core_logic/core_logic.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('restaura la vista comercial sin tocar piezas reales', () {
    final row = SaleDetailPresentationMapper.restore({
      'cantidad': 12,
      'piezas_reales': 12,
      'tipo_unidad': 'unidad',
      'precio_unitario_comercial': 2,
      'subtotal': 22,
      'presentation_snapshot': {
        'schema_version': 1,
        'quantity': 2,
        'commercial_price': 11,
        'code': 'pack_6',
        'singular': 'Pack',
        'plural': 'Packs',
        'factor': 6,
        'base_code': 'botella',
        'base_label': 'Botella',
        'revision': 4,
      },
    });
    expect(row['cantidad'], 2);
    expect(row['piezas_reales'], 12);
    expect(row['tipo_unidad'], 'pack_6');
    expect(row['precio_unitario_comercial'], 11);
    expect(row['unit_profile_revision_snapshot'], 4);
  });

  test('rechaza snapshots dañados en vez de inventar cantidades', () {
    expect(
      () => SaleDetailPresentationMapper.restore({
        'presentation_snapshot': {'schema_version': 1, 'quantity': 'dos'},
      }),
      throwsFormatException,
    );
  });

  test('rechaza un snapshot que no coincide con las piezas descontadas', () {
    expect(
      () => SaleDetailPresentationMapper.restore({
        'piezas_reales': 11,
        'subtotal': 22,
        'presentation_snapshot': {
          'schema_version': 1,
          'quantity': 2,
          'commercial_price': 11,
          'code': 'pack_6',
          'singular': 'Pack',
          'plural': 'Packs',
          'factor': 6,
          'base_code': 'botella',
          'base_label': 'Botella',
          'revision': 4,
        },
      }),
      throwsFormatException,
    );
  });
}
