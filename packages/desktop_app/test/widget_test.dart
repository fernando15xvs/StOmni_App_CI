import 'package:core_logic/core_logic.dart';
import 'package:desktop_app/features/home/desktop_home_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('desktop consume el mismo dominio de ventas que mobile', () {
    final totals = SaleTotals.calculate(
      subtotal: 100,
      discountInput: 10,
      discountMode: SaleDiscountMode.percentage,
    );

    expect(totals.discountAmount, 10);
    expect(totals.total, 90);
  });

  test('desktop puede construir presentaciones comerciales genéricas', () {
    final unit = CommercialPresentation.base(
      code: 'unidad',
      singularLabel: 'Unidad',
      pluralLabel: 'Unidades',
    );
    final box = CommercialPresentation(
      code: 'caja',
      singularLabel: 'Caja',
      pluralLabel: 'Cajas',
      baseQuantity: 12,
    );
    final profile = ProductUnitProfile(
      baseUnit: unit,
      presentations: [unit, box],
    );

    expect(profile.toBaseQuantity(presentationCode: 'caja', quantity: 2), 24);
  });

  testWidgets(
    'sidebar desktop sigue navegable con muchos destinos y poca altura',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(900, 320));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final destinations = List.generate(
        18,
        (index) => DesktopNavigationItem(
          BusinessModule.dashboard,
          Icons.circle_outlined,
          Icons.circle,
          'Destino $index',
        ),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Row(
              children: [
                DesktopNavigationSidebar(
                  branding: null,
                  destinations: destinations,
                  selectedIndex: 0,
                  onDestinationSelected: (_) {},
                ),
                const Expanded(child: SizedBox()),
              ],
            ),
          ),
        ),
      );

      expect(tester.takeException(), isNull);
      expect(find.text('Destino 0'), findsOneWidget);

      await tester.scrollUntilVisible(
        find.text('Destino 17'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();

      expect(find.text('Destino 17'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
