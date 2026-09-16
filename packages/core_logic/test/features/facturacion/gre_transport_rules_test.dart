import 'package:core_logic/core_logic.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('GreTransportRules', () {
    test('resuelve flujo de transporte sin depender de UI', () {
      expect(
        GreTransportRules.flujo(
          tipoGuia: 'transportista',
          modalidad: '01',
          indTransbordo: false,
        ),
        'transportista',
      );
      expect(
        GreTransportRules.flujo(
          tipoGuia: 'remitente',
          modalidad: '01',
          indTransbordo: false,
        ),
        'publico',
      );
      expect(
        GreTransportRules.flujo(
          tipoGuia: 'remitente',
          modalidad: '02',
          indTransbordo: true,
        ),
        'transbordo',
      );
    });

    test(
      'filtra agencias y conserva una seleccionada aunque esté inactiva',
      () {
        final agencias = <Map<String, dynamic>>[
          {
            'id': 1,
            'transportista_id': 9,
            'permite_origen': true,
            'permite_destino': false,
            'activo': true,
          },
          {
            'id': 2,
            'transportista_id': 9,
            'permite_origen': false,
            'permite_destino': true,
            'activo': false,
          },
          {
            'id': 3,
            'transportista_id': 10,
            'permite_origen': true,
            'permite_destino': true,
            'activo': true,
          },
        ];

        final origen = GreTransportRules.agenciasDelTransportista(
          agencias: agencias,
          transportistaId: 9,
          origen: true,
        );
        expect(origen.map((e) => e['id']), [1]);

        final destinoSeleccionado = GreTransportRules.agenciasDelTransportista(
          agencias: agencias,
          transportistaId: 9,
          origen: false,
          agenciaDestinoId: 2,
        );
        expect(destinoSeleccionado.map((e) => e['id']), [2]);
      },
    );

    test('formatea nombre de agencia con distrito', () {
      expect(
        GreTransportRules.textoAgencia({
          'nombre': 'Sucursal Norte',
          'distrito': 'Chiclayo',
        }),
        'Sucursal Norte · Chiclayo',
      );
    });
  });
}
