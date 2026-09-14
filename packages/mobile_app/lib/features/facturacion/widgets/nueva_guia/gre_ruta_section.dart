import 'package:flutter/material.dart';

import '../../../../core/widgets/document_form_kit.dart';
import '../gre_ubigeo_field.dart';
import 'gre_form_card.dart';

class GreRutaSection extends StatelessWidget {
  const GreRutaSection({
    super.key,
    required this.color,
    required this.destTipo,
    required this.destDocCtrl,
    required this.destNombreCtrl,
    required this.destDireccionCtrl,
    required this.destUbigeoCtrl,
    required this.partidaDireccionCtrl,
    required this.partidaUbigeoCtrl,
    required this.llegadaDireccionCtrl,
    required this.llegadaUbigeoCtrl,
    required this.almacenes,
    required this.almacenPartidaId,
    required this.consultandoDestinatario,
    required this.indTransbordo,
    required this.destinoEntregaTipo,
    required this.onDestTipoChanged,
    required this.onConsultarDestinatario,
    required this.onAlmacenChanged,
    required this.onUsarDireccionCliente,
    required this.onLlegadaUbigeoSelected,
  });

  final Color color;
  final String destTipo;
  final TextEditingController destDocCtrl;
  final TextEditingController destNombreCtrl;
  final TextEditingController destDireccionCtrl;
  final TextEditingController destUbigeoCtrl;
  final TextEditingController partidaDireccionCtrl;
  final TextEditingController partidaUbigeoCtrl;
  final TextEditingController llegadaDireccionCtrl;
  final TextEditingController llegadaUbigeoCtrl;
  final List<Map<String, dynamic>> almacenes;
  final int? almacenPartidaId;
  final bool consultandoDestinatario;
  final bool indTransbordo;
  final String destinoEntregaTipo;
  final ValueChanged<String> onDestTipoChanged;
  final VoidCallback onConsultarDestinatario;
  final ValueChanged<int?> onAlmacenChanged;
  final VoidCallback onUsarDireccionCliente;
  final ValueChanged<Map<String, dynamic>> onLlegadaUbigeoSelected;

  bool get _llegadaEsAgencia =>
      indTransbordo && destinoEntregaTipo == 'agencia';

  @override
  Widget build(BuildContext context) {
    return GreFormCard(
      title: 'Destinatario y ruta',
      color: color,
      child: Column(
        children: [
          Row(
            children: [
              SizedBox(
                width: 110,
                child: DropdownButtonFormField<String>(
                  isExpanded: true,
                  initialValue: destTipo,
                  items: const [
                    DropdownMenuItem(value: '1', child: Text('1 · DNI')),
                    DropdownMenuItem(value: '6', child: Text('6 · RUC')),
                    DropdownMenuItem(value: '4', child: Text('4 · CE')),
                    DropdownMenuItem(value: '7', child: Text('7 · Pasap.')),
                  ],
                  onChanged: (value) {
                    if (value != null) onDestTipoChanged(value);
                  },
                  decoration: _input(context, 'Tipo', Icons.badge),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  controller: destDocCtrl,
                  decoration: _input(context, 'Documento', Icons.edit).copyWith(
                    suffixIcon: IconButton(
                      icon: consultandoDestinatario
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.search),
                      onPressed: consultandoDestinatario
                          ? null
                          : onConsultarDestinatario,
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          ClienteAutocompleteField(
            nombreCtrl: destNombreCtrl,
            rucCtrl: destDocCtrl,
            direccionCtrl: destDireccionCtrl,
            color: color,
          ),
          const SizedBox(height: 10),
          _text(context, destDireccionCtrl, 'Dirección del destinatario'),
          if (!_llegadaEsAgencia)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                style: TextButton.styleFrom(foregroundColor: color),
                onPressed: onUsarDireccionCliente,
                icon: const Icon(Icons.south_rounded),
                label: const Text('USAR COMO PUNTO DE LLEGADA'),
              ),
            ),
          const SizedBox(height: 4),
          if (almacenes.isNotEmpty)
            DropdownButtonFormField<int>(
              initialValue: almacenPartidaId,
              items: almacenes
                  .map(
                    (item) => DropdownMenuItem(
                      value: (item['id'] as num).toInt(),
                      child: Text(item['nombre']?.toString() ?? ''),
                    ),
                  )
                  .toList(),
              onChanged: onAlmacenChanged,
              decoration: _input(
                context,
                'Almacén / punto de partida',
                Icons.storefront,
              ),
            ),
          const SizedBox(height: 10),
          _text(context, partidaDireccionCtrl, 'Dirección de partida'),
          const SizedBox(height: 10),
          GreUbigeoField(
            controller: partidaUbigeoCtrl,
            label: 'Ubigeo de partida',
          ),
          const SizedBox(height: 10),
          if (_llegadaEsAgencia)
            _agenciaDestinoInfo(context)
          else ...[
            _text(context, llegadaDireccionCtrl, 'Dirección de llegada'),
            const SizedBox(height: 10),
            GreUbigeoField(
              controller: llegadaUbigeoCtrl,
              label: 'Ubigeo de llegada',
              onSelected: onLlegadaUbigeoSelected,
            ),
          ],
        ],
      ),
    );
  }

  Widget _agenciaDestinoInfo(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Punto de llegada final',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 4),
          Text(
            llegadaDireccionCtrl.text.trim().isEmpty
                ? 'Selecciona la agencia de destino en Transporte.'
                : llegadaDireccionCtrl.text.trim(),
          ),
          if (llegadaUbigeoCtrl.text.trim().isNotEmpty)
            Text(
              'Ubigeo: ${llegadaUbigeoCtrl.text.trim()}',
              style: TextStyle(color: Colors.grey.shade600),
            ),
        ],
      ),
    );
  }

  Widget _text(
    BuildContext context,
    TextEditingController controller,
    String label,
  ) {
    return TextField(
      controller: controller,
      decoration: _input(context, label, Icons.edit),
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
