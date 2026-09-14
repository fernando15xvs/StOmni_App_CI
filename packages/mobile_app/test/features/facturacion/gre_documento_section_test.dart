import 'package:mobile_app/features/facturacion/widgets/nueva_guia/gre_documento_section.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const motivos = <String, String>{
    '01': 'VENTA',
    '04': 'TRASLADO ENTRE ESTABLECIMIENTOS DE LA MISMA EMPRESA',
  };

  Widget buildSection({
    String tipoGuia = 'remitente',
    VoidCallback? onFecha,
    ValueChanged<String>? onTipo,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: GreDocumentoSection(
            color: Colors.deepPurple,
            tipoGuia: tipoGuia,
            motivoCodigo: '01',
            motivos: motivos,
            documentoTipo: null,
            documentoNumeroCtrl: TextEditingController(),
            fechaTraslado: DateTime(2026, 8, 19, 18, 30),
            observacionCtrl: TextEditingController(),
            remDocCtrl: TextEditingController(),
            remNombreCtrl: TextEditingController(),
            onTipoGuiaChanged: onTipo ?? (_) {},
            onMotivoCodigoChanged: (_) {},
            onDocumentoTipoChanged: (_) {},
            onElegirFechaTraslado: onFecha ?? () {},
          ),
        ),
      ),
    );
  }

  testWidgets('muestra campos del remitente para GRE Transportista', (
    tester,
  ) async {
    await tester.pumpWidget(buildSection(tipoGuia: 'transportista'));

    expect(find.text('Documento'), findsOneWidget);
    expect(find.text('RUC del remitente'), findsOneWidget);
    expect(find.text('Razón social remitente'), findsOneWidget);
    expect(
      find.textContaining('La GRE Transportista la emite quien presta'),
      findsOneWidget,
    );
  });

  testWidgets('conserva callbacks de tipo de guía y fecha de traslado', (
    tester,
  ) async {
    String? tipoSeleccionado;
    var fechaPulsada = false;

    await tester.pumpWidget(
      buildSection(
        onTipo: (value) => tipoSeleccionado = value,
        onFecha: () => fechaPulsada = true,
      ),
    );

    final dropdowns = tester
        .widgetList<DropdownButtonFormField<String>>(
          find.byType(DropdownButtonFormField<String>),
        )
        .toList();

    expect(dropdowns.length, 3);
    dropdowns.first.onChanged?.call('transportista');
    expect(tipoSeleccionado, 'transportista');

    final fechaFinder = find.text('Inicio previsto del traslado');
    await tester.ensureVisible(fechaFinder);
    await tester.tap(fechaFinder);
    expect(fechaPulsada, isTrue);
  });
}
