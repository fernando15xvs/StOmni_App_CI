import 'package:mobile_app/features/facturacion/widgets/nueva_guia/gre_form_actions.dart';
import 'package:mobile_app/features/facturacion/widgets/nueva_guia/gre_peso_section.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('GreFormActions ejecuta borrador y emitir', (tester) async {
    var borradores = 0;
    var emisiones = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: GreFormActions(
            color: Colors.deepPurple,
            guardando: false,
            onGuardarBorrador: () => borradores++,
            onEmitir: () => emisiones++,
          ),
        ),
      ),
    );

    await tester.tap(find.text('BORRADOR'));
    await tester.tap(find.text('EMITIR GUÍA'));

    expect(borradores, 1);
    expect(emisiones, 1);
  });

  testWidgets('GreFormActions bloquea acciones mientras guarda', (
    tester,
  ) async {
    var acciones = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: GreFormActions(
            color: Colors.deepPurple,
            guardando: true,
            onGuardarBorrador: () => acciones++,
            onEmitir: () => acciones++,
          ),
        ),
      ),
    );

    expect(find.text('PROCESANDO...'), findsOneWidget);

    await tester.tap(find.text('BORRADOR'), warnIfMissed: false);
    await tester.tap(find.text('PROCESANDO...'), warnIfMissed: false);

    expect(acciones, 0);
  });

  testWidgets('GrePesoSection conserva peso y número de bultos', (
    tester,
  ) async {
    final pesoController = TextEditingController(text: '4.000');
    final bultosController = TextEditingController();
    var cambio = '';
    var recalculos = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: GrePesoSection(
              color: Colors.deepPurple,
              controller: pesoController,
              cantidadBultosController: bultosController,
              pesoEditado: true,
              onPesoChanged: (value) => cambio = value,
              onRecalcular: () => recalculos++,
            ),
          ),
        ),
      ),
    );

    final fields = find.byType(TextField);
    expect(fields, findsNWidgets(2));

    await tester.enterText(fields.at(0), '5.500');
    await tester.enterText(fields.at(1), '3');
    await tester.tap(find.text('VOLVER A CALCULAR'));

    expect(cambio, '5.500');
    expect(bultosController.text, '3');
    expect(recalculos, 1);
    expect(find.text('Número de bultos (opcional)'), findsOneWidget);

    pesoController.dispose();
    bultosController.dispose();
  });
}
