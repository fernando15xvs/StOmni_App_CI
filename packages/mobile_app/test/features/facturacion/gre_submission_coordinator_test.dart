import 'package:mobile_app/features/facturacion/presentation/controllers/gre_submission_coordinator.dart';
import 'package:mobile_app/features/facturacion/presentation/state/gre_form_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const motivos = <String, String>{'01': 'VENTA', '04': 'TRASLADO'};
  final ahoraFijo = DateTime.utc(2026, 8, 19, 18, 0);

  GreFormModel baseConDetalle() {
    final form = GreFormModel();
    form.detalles.add({
      'producto_id': 1,
      'almacen_id': 1,
      'cantidad': 1.0,
      'piezas_reales': 1,
      'peso_total_kg': 1.0,
    });
    form.recalcularPeso();
    return form;
  }

  group('GreSubmissionCoordinator', () {
    test('rechaza guardar sin productos', () {
      final form = GreFormModel();
      addTearDown(form.dispose);

      expect(
        () => GreSubmissionCoordinator.preparar(
          form: form,
          emitir: false,
          motivos: motivos,
        ),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'mensaje',
            'Agrega al menos un producto.',
          ),
        ),
      );
    });

    test('borrador permite peso vacío y bultos vacíos', () {
      final form = baseConDetalle();
      addTearDown(form.dispose);
      form.pesoTotalCtrl.clear();

      final prepared = GreSubmissionCoordinator.preparar(
        form: form,
        emitir: false,
        motivos: motivos,
      );

      expect(prepared.emitir, isFalse);
      expect(prepared.peso, isNull);
      expect(prepared.cantidadBultos, isNull);
      expect(prepared.origenTipo, 'manual');
    });

    test('bultos válidos se preparan como entero', () {
      final form = baseConDetalle();
      addTearDown(form.dispose);
      form.cantidadBultosCtrl.text = '12';

      final prepared = GreSubmissionCoordinator.preparar(
        form: form,
        emitir: false,
        motivos: motivos,
      );

      expect(prepared.cantidadBultos, 12);
    });

    test('bultos cero o inválidos se rechazan', () {
      final form = baseConDetalle();
      addTearDown(form.dispose);

      for (final value in ['0', '-2', '1.5', 'abc']) {
        form.cantidadBultosCtrl.text = value;
        expect(
          () => GreSubmissionCoordinator.preparar(
            form: form,
            emitir: false,
            motivos: motivos,
          ),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'mensaje',
              contains('entero mayor a cero'),
            ),
          ),
          reason: 'Debe rechazar cantidad_bultos=$value',
        );
      }
    });

    test('venta multialmacén se rechaza antes de persistir', () {
      final form = baseConDetalle();
      addTearDown(form.dispose);
      form.detalles.add({
        'producto_id': 2,
        'almacen_id': 2,
        'cantidad': 1.0,
        'piezas_reales': 1,
        'peso_total_kg': 1.0,
      });

      expect(
        () => GreSubmissionCoordinator.preparar(
          form: form,
          emitir: false,
          motivos: motivos,
          ventaId: 99,
        ),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'mensaje',
            contains('varios almacenes'),
          ),
        ),
      );
    });

    test('emisión exige ruta válida', () {
      final form = baseConDetalle();
      addTearDown(form.dispose);
      form.fechaTraslado = ahoraFijo.add(const Duration(hours: 2));

      expect(
        () => GreSubmissionCoordinator.preparar(
          form: form,
          emitir: true,
          motivos: motivos,
          ahoraLima: ahoraFijo,
        ),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'mensaje',
            contains('dirección y ubigeo válidos de partida'),
          ),
        ),
      );
    });

    test('GRE transportista preparada fuerza documento relacionado 09', () {
      final form = baseConDetalle();
      addTearDown(form.dispose);

      form.tipoGuia = 'transportista';
      form.modalidad = '01';
      form.fechaTraslado = ahoraFijo.add(const Duration(hours: 2));
      form.partidaDireccionCtrl.text = 'Av. Partida 123';
      form.partidaUbigeoCtrl.text = '150101';
      form.llegadaDireccionCtrl.text = 'Av. Llegada 456';
      form.llegadaUbigeoCtrl.text = '140101';
      form.destDocCtrl.text = '20123456789';
      form.destNombreCtrl.text = 'Destinatario SAC';
      form.empresa = {'gre_transportista_habilitada': true};
      form.remDocCtrl.text = '20987654321';
      form.remNombreCtrl.text = 'Remitente SAC';
      form.documentoNumeroCtrl.text = 'T001-123';
      form.cantidadBultosCtrl.text = '4';
      form.conductorId = 7;
      form.vehiculoId = 8;
      form.conductores = [
        {
          'id': 7,
          'numero_licencia': 'Q12345678',
          'nombres': 'Juan',
          'apellidos': 'Pérez',
        },
      ];
      form.vehiculos = [
        {
          'id': 8,
          'placa': 'ABC123',
          'marca': 'Toyota',
          'constancia_inscripcion': 'MTC-1',
        },
      ];

      final prepared = GreSubmissionCoordinator.preparar(
        form: form,
        emitir: true,
        motivos: motivos,
        ahoraLima: ahoraFijo,
      );

      expect(prepared.emitir, isTrue);
      expect(form.documentoTipo, '09');
      expect(prepared.peso, 1.0);
      expect(prepared.cantidadBultos, 4);
      expect(form.fechaEmision, ahoraFijo);
    });
  });
}
