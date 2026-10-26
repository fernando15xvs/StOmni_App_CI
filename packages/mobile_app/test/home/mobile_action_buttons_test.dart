import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_app/home/widgets/glass_fab.dart';

void main() {
  testWidgets('Ingreso secundario respeta tema oscuro y se puede pulsar', (
    tester,
  ) async {
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: Scaffold(
          body: Center(
            child: GlassFab(
              onPressed: () => taps++,
              icon: Icons.move_to_inbox,
              label: 'Ingreso prod.',
              baseColor: const Color(0xFF111111),
              outlined: true,
            ),
          ),
        ),
      ),
    );
    expect(find.text('Ingreso prod.'), findsOneWidget);
    final icon = tester.widget<Icon>(find.byIcon(Icons.move_to_inbox));
    expect(icon.color, ThemeData.dark(useMaterial3: true).colorScheme.onSurface);
    await tester.tap(find.text('Ingreso prod.'));
    expect(taps, 1);
  });

  testWidgets('Acción principal conserva el color de acento', (tester) async {
    const accent = Color(0xFF00A87E);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: GlassFab(
            onPressed: () {},
            icon: Icons.add,
            label: 'Crear producto',
            baseColor: accent,
          ),
        ),
      ),
    );
    final ink = tester.widget<Ink>(find.byType(Ink));
    expect((ink.decoration! as BoxDecoration).color, accent);
  });
}
