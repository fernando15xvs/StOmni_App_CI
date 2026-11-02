import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Detalle de inventario acepta stock num producido por el catálogo', () {
    final source = File(
      'lib/features/almacen/widgets/producto_detail_sheet.dart',
    ).readAsStringSync();

    expect(source, contains("(p['_totalStock'] as num?)?.toInt() ?? 0"));
    expect(source, contains("(producto['_totalStock'] as num?)?.toInt() ?? 0"));
    expect(source, isNot(contains("['_totalStock'] as int?")));
  });
}
