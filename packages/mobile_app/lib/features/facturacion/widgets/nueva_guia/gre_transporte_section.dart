import 'package:flutter/material.dart';

import 'package:core_logic/core_logic.dart';
import 'gre_form_card.dart';

class GreTransporteSection extends StatelessWidget {
  const GreTransporteSection({
    super.key,
    required this.color,
    required this.tipoGuia,
    required this.modalidad,
    required this.indTransbordo,
    required this.transportistaId,
    required this.conductorId,
    required this.vehiculoId,
    required this.transportistaTransbordoId,
    required this.agenciaOrigenId,
    required this.agenciaDestinoId,
    required this.destinoEntregaTipo,
    required this.transportistas,
    required this.agencias,
    required this.conductores,
    required this.vehiculos,
    required this.onFlujoChanged,
    required this.onTransportistaChanged,
    required this.onConductorChanged,
    required this.onVehiculoChanged,
    required this.onTransportistaTransbordoChanged,
    required this.onAgenciaOrigenChanged,
    required this.onDestinoEntregaTipoChanged,
    required this.onAgenciaDestinoChanged,
  });

  final Color color;
  final String tipoGuia;
  final String modalidad;
  final bool indTransbordo;
  final int? transportistaId;
  final int? conductorId;
  final int? vehiculoId;
  final int? transportistaTransbordoId;
  final int? agenciaOrigenId;
  final int? agenciaDestinoId;
  final String destinoEntregaTipo;
  final List<Map<String, dynamic>> transportistas;
  final List<Map<String, dynamic>> agencias;
  final List<Map<String, dynamic>> conductores;
  final List<Map<String, dynamic>> vehiculos;
  final ValueChanged<String> onFlujoChanged;
  final ValueChanged<int?> onTransportistaChanged;
  final ValueChanged<int?> onConductorChanged;
  final ValueChanged<int?> onVehiculoChanged;
  final ValueChanged<int?> onTransportistaTransbordoChanged;
  final ValueChanged<int?> onAgenciaOrigenChanged;
  final ValueChanged<String> onDestinoEntregaTipoChanged;
  final ValueChanged<int?> onAgenciaDestinoChanged;

  @override
  Widget build(BuildContext context) {
    final flujo = GreTransportRules.flujo(
      tipoGuia: tipoGuia,
      modalidad: modalidad,
      indTransbordo: indTransbordo,
    );
    final agenciasOrigen = GreTransportRules.agenciasDelTransportista(
      agencias: agencias,
      transportistaId: transportistaTransbordoId,
      origen: true,
      agenciaOrigenId: agenciaOrigenId,
      agenciaDestinoId: agenciaDestinoId,
    );
    final agenciasDestino = GreTransportRules.agenciasDelTransportista(
      agencias: agencias,
      transportistaId: transportistaTransbordoId,
      origen: false,
      agenciaOrigenId: agenciaOrigenId,
      agenciaDestinoId: agenciaDestinoId,
    );

    return GreFormCard(
      title: 'Transporte',
      color: color,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          DropdownButtonFormField<String>(
            isExpanded: true,
            initialValue: flujo,
            items: tipoGuia == 'transportista'
                ? const [
                    DropdownMenuItem(
                      value: 'transportista',
                      child: Text('GRE Transportista de mi empresa'),
                    ),
                  ]
                : const [
                    DropdownMenuItem(
                      value: 'privado',
                      child: Text('Transporte Privado'),
                    ),
                    DropdownMenuItem(
                      value: 'publico',
                      child: Text('Transporte Publico'),
                    ),
                    DropdownMenuItem(
                      value: 'transbordo',
                      child: Text('Traslado hasta una agencia'),
                    ),
                  ],
            onChanged: tipoGuia == 'transportista'
                ? null
                : (value) {
                    if (value != null) onFlujoChanged(value);
                  },
            decoration: _input(
              context,
              'Cómo se realizará el traslado',
              Icons.route,
            ),
          ),
          if (modalidad == '01' && tipoGuia == 'remitente') ...[
            const SizedBox(height: 10),
            _dropdown(
              context: context,
              label: 'Empresa transportista',
              value: transportistaId,
              items: transportistas,
              text: (item) => item['razon_social']?.toString() ?? '',
              onChanged: onTransportistaChanged,
            ),
            const SizedBox(height: 8),
            Text(
              'La empresa recoge los productos en tu punto de partida. '
              'No necesitas registrar su conductor ni su placa.',
              style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
            ),
          ] else ...[
            const SizedBox(height: 10),
            _dropdown(
              context: context,
              label: indTransbordo ? 'Conductor del primer tramo' : 'Conductor',
              value: conductorId,
              items: conductores,
              text: (item) {
                final nombres = item['nombres']?.toString() ?? '';
                final apellidos = item['apellidos']?.toString() ?? '';
                final licencia = item['numero_licencia']?.toString() ?? '';
                return '$nombres $apellidos · Lic. $licencia'.trim();
              },
              onChanged: onConductorChanged,
            ),
            const SizedBox(height: 10),
            _dropdown(
              context: context,
              label: indTransbordo ? 'Vehículo del primer tramo' : 'Vehículo',
              value: vehiculoId,
              items: vehiculos,
              text: (item) {
                final marca = item['marca']?.toString() ?? '';
                final constancia =
                    item['constancia_inscripcion']?.toString() ?? '';
                return '${item['placa']} · $marca · $constancia';
              },
              onChanged: onVehiculoChanged,
            ),
          ],
          if (indTransbordo && tipoGuia == 'remitente') ...[
            const SizedBox(height: 14),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.amber.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Text(
                'La GRE Remitente se emitirá con transporte privado e '
                'indicador de transbordo programado. El conductor y el '
                'vehículo corresponden al recorrido desde tu almacén hasta '
                'la agencia. La transportista emitirá su propia GRE para el '
                'tramo que realiza.',
              ),
            ),
            const SizedBox(height: 12),
            _dropdown(
              context: context,
              label: 'Empresa que continuará el traslado',
              value: transportistaTransbordoId,
              items: transportistas,
              text: (item) => item['razon_social']?.toString() ?? '',
              onChanged: onTransportistaTransbordoChanged,
            ),
            const SizedBox(height: 10),
            _dropdown(
              context: context,
              label: 'Agencia donde entregarás el pedido',
              value: agenciaOrigenId,
              items: agenciasOrigen,
              text: GreTransportRules.textoAgencia,
              onChanged: onAgenciaOrigenChanged,
            ),
            const SizedBox(height: 10),
            DropdownButtonFormField<String>(
              isExpanded: true,
              initialValue: destinoEntregaTipo,
              items: const [
                DropdownMenuItem(
                  value: 'agencia',
                  child: Text('El cliente recoge en una agencia'),
                ),
                DropdownMenuItem(
                  value: 'direccion_cliente',
                  child: Text('Entrega en la dirección del cliente'),
                ),
              ],
              onChanged: (value) {
                if (value != null) onDestinoEntregaTipoChanged(value);
              },
              decoration: _input(context, 'Destino final', Icons.flag_outlined),
            ),
            if (destinoEntregaTipo == 'agencia') ...[
              const SizedBox(height: 10),
              _dropdown(
                context: context,
                label: 'Agencia de destino',
                value: agenciaDestinoId,
                items: agenciasDestino,
                text: GreTransportRules.textoAgencia,
                onChanged: onAgenciaDestinoChanged,
              ),
            ],
            if (transportistaTransbordoId != null &&
                agenciasOrigen.isEmpty) ...[
              const SizedBox(height: 8),
              Text(
                'Este transportista no tiene agencias de origen activas. '
                'Regístralas en Gestión de transporte.',
                style: TextStyle(color: Colors.red.shade700, fontSize: 12),
              ),
            ],
          ],
        ],
      ),
    );
  }

  Widget _dropdown({
    required BuildContext context,
    required String label,
    required int? value,
    required List<Map<String, dynamic>> items,
    required String Function(Map<String, dynamic>) text,
    required ValueChanged<int?> onChanged,
  }) {
    return DropdownButtonFormField<int>(
      isExpanded: true,
      initialValue: value,
      items: items
          .map(
            (item) => DropdownMenuItem(
              value: (item['id'] as num).toInt(),
              child: Text(text(item), overflow: TextOverflow.ellipsis),
            ),
          )
          .toList(),
      onChanged: onChanged,
      decoration: _input(context, label, Icons.badge),
    );
  }

  InputDecoration _input(BuildContext context, String label, IconData icon) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return InputDecoration(
      labelText: label,
      floatingLabelStyle: TextStyle(color: color),
      prefixIcon: Icon(
        icon,
        color: isDark ? Colors.grey[400] : Colors.grey[600],
        size: 20,
      ),
      filled: true,
      fillColor: isDark
          ? Colors.white.withValues(alpha: 0.04)
          : Colors.grey.withValues(alpha: 0.05),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(
          color: isDark
              ? Colors.white.withValues(alpha: 0.1)
              : Colors.grey.withValues(alpha: 0.2),
        ),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(color: color, width: 2),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
    );
  }
}
