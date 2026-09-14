import 'package:mobile_app/features/facturacion/presentation/state/gre_form_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('GreFormModel', () {
    test('carga origen venta y deriva almacén/peso sin depender de la página', () {
      final model = GreFormModel();
      addTearDown(model.dispose);

      model.cargarDesdeBase({
        'empresa': {'ruc': '20123456789', 'razon_social': 'Empresa'},
        'almacenes': [
          {'id': 3, 'nombre': 'Principal', 'direccion': 'Av. Uno', 'ubigeo': '150101'},
        ],
        'transportistas': <Map<String, dynamic>>[],
        'agencias': <Map<String, dynamic>>[],
        'conductores': <Map<String, dynamic>>[],
        'vehiculos': <Map<String, dynamic>>[],
        'productos': <Map<String, dynamic>>[],
        'guia_edicion': null,
        'origen': {
          'tipo': 'venta',
          'venta': {
            'clientes': {
              'dni_ruc': '12345678',
              'nombre': 'Cliente Uno',
              'direccion': 'Calle Dos',
            },
          },
          'comprobante': null,
          'detalles': [
            {
              'id': 10,
              'producto_id': 7,
              'almacen_id': 3,
              'tipo_unidad': 'unidad',
              'cantidad': 2,
              'piezas_reales': 2,
              'productos': {
                'id': 7,
                'nombre': 'Tornillo',
                'tipo_venta': 'UNIDAD',
                'peso_kg': 0.5,
              },
            },
          ],
        },
      });

      expect(model.destTipo, '1');
      expect(model.destDocCtrl.text, '12345678');
      expect(model.almacenPartidaId, 3);
      expect(model.partidaDireccionCtrl.text, 'Av. Uno');
      expect(model.detalles.single['peso_total_kg'], 1.0);
      expect(model.pesoTotalCtrl.text, '1.000');
    });

    test('rehidrata cantidad de bultos al reabrir una guía', () {
      final model = GreFormModel();
      addTearDown(model.dispose);

      model.aplicarGuiaExistente({
        'guia': {
          'request_id': 'b0d50998-11c0-4faa-b370-7cc430103a31',
          'tipo_guia': 'remitente',
          'motivo_codigo': '01',
          'modalidad_transporte': '02',
          'cantidad_bultos': 7,
        },
        'detalles': <Map<String, dynamic>>[],
      });

      expect(model.cantidadBultosCtrl.text, '7');
    });

    test('actualiza tipo de destinatario desde longitud del documento', () {
      final model = GreFormModel();
      addTearDown(model.dispose);

      model.destDocCtrl.text = '12345678';
      model.actualizarTipoDestinatarioDesdeDocumento();
      expect(model.destTipo, '1');

      model.destDocCtrl.text = '20123456789';
      model.actualizarTipoDestinatarioDesdeDocumento();
      expect(model.destTipo, '6');
    });

    test('agencia de destino reemplaza llegada y cliente puede restaurarla', () {
      final model = GreFormModel();
      addTearDown(model.dispose);
      model.agencias = [
        {
          'id': 4,
          'direccion': 'Agencia Centro',
          'ubigeo': '140101',
        },
      ];
      model.destDireccionCtrl.text = 'Casa Cliente';
      model.destUbigeoCtrl.text = '140102';

      model.aplicarAgenciaDestino(4);
      expect(model.llegadaDireccionCtrl.text, 'Agencia Centro');
      expect(model.llegadaUbigeoCtrl.text, '140101');

      model.usarDireccionClienteComoLlegada();
      expect(model.agenciaDestinoId, isNull);
      expect(model.llegadaDireccionCtrl.text, 'Casa Cliente');
      expect(model.llegadaUbigeoCtrl.text, '140102');
    });
  });
}
