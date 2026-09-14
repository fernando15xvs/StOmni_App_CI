import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'gre_form_card.dart';

class GreDocumentoSection extends StatelessWidget {
  const GreDocumentoSection({
    super.key,
    required this.color,
    required this.tipoGuia,
    required this.motivoCodigo,
    required this.motivos,
    required this.documentoTipo,
    required this.documentoNumeroCtrl,
    required this.fechaTraslado,
    required this.observacionCtrl,
    required this.remDocCtrl,
    required this.remNombreCtrl,
    required this.onTipoGuiaChanged,
    required this.onMotivoCodigoChanged,
    required this.onDocumentoTipoChanged,
    required this.onElegirFechaTraslado,
  });

  final Color color;
  final String tipoGuia;
  final String motivoCodigo;
  final Map<String, String> motivos;
  final String? documentoTipo;
  final TextEditingController documentoNumeroCtrl;
  final DateTime fechaTraslado;
  final TextEditingController observacionCtrl;
  final TextEditingController remDocCtrl;
  final TextEditingController remNombreCtrl;
  final ValueChanged<String> onTipoGuiaChanged;
  final ValueChanged<String> onMotivoCodigoChanged;
  final ValueChanged<String?> onDocumentoTipoChanged;
  final VoidCallback onElegirFechaTraslado;

  @override
  Widget build(BuildContext context) {
    return GreFormCard(
      title: 'Documento',
      color: color,
      child: Column(
        children: [
          DropdownButtonFormField<String>(
            isExpanded: true,
            initialValue: tipoGuia,
            items: const [
              DropdownMenuItem(
                value: 'remitente',
                child: Text('GRE Remitente · T001'),
              ),
              DropdownMenuItem(
                value: 'transportista',
                child: Text('GRE Transportista · V001'),
              ),
            ],
            onChanged: (value) {
              if (value != null) onTipoGuiaChanged(value);
            },
            decoration: _input(context, 'Tipo de guía', Icons.receipt_long),
          ),
          if (tipoGuia == 'transportista') ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.orange.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Text(
                'La GRE Transportista la emite quien presta el servicio '
                'de transporte. No la uses solo porque contrataste a un tercero.',
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(child: _text(context, remDocCtrl, 'RUC del remitente')),
                const SizedBox(width: 10),
                Expanded(
                  flex: 2,
                  child: _text(
                    context,
                    remNombreCtrl,
                    'Razón social remitente',
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 10),
          DropdownButtonFormField<String>(
            isExpanded: true,
            initialValue: motivoCodigo,
            items: motivos.entries
                .map(
                  (entry) => DropdownMenuItem(
                    value: entry.key,
                    child: Text('${entry.key} · ${entry.value}'),
                  ),
                )
                .toList(),
            onChanged: (value) {
              if (value != null) onMotivoCodigoChanged(value);
            },
            decoration: _input(context, 'Motivo de traslado', Icons.alt_route),
          ),
          const SizedBox(height: 10),
          DropdownButtonFormField<String>(
            isExpanded: true,
            initialValue: documentoTipo,
            items: const [
              DropdownMenuItem(value: null, child: Text('Ninguno (Opcional)')),
              DropdownMenuItem(value: '01', child: Text('01 · Factura')),
              DropdownMenuItem(value: '03', child: Text('03 · Boleta')),
              DropdownMenuItem(
                value: '09',
                child: Text('09 · Guía de Remisión'),
              ),
            ],
            onChanged: onDocumentoTipoChanged,
            decoration: _input(
              context,
              'Tipo de doc. relacionado',
              Icons.description,
            ),
          ),
          const SizedBox(height: 10),
          _text(
            context,
            documentoNumeroCtrl,
            'Número de documento relacionado',
            hint: 'Ej: F001-10 / B001-20',
          ),
          const SizedBox(height: 10),
          _fechaEmisionInfo(context),
          const SizedBox(height: 10),
          _dateTile(
            context,
            'Inicio previsto del traslado',
            fechaTraslado,
            onElegirFechaTraslado,
          ),
          const SizedBox(height: 8),
          _text(context, observacionCtrl, 'Observación', maxLines: 2),
        ],
      ),
    );
  }

  Widget _fechaEmisionInfo(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: isDark
            ? Colors.white.withValues(alpha: 0.04)
            : Colors.grey.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Icon(
            Icons.calendar_month,
            color: isDark ? Colors.grey[400] : Colors.grey[600],
            size: 20,
          ),
          const SizedBox(width: 14),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Fecha de emisión',
                  style: TextStyle(fontSize: 12),
                ),
                SizedBox(height: 4),
                Text(
                  'Se asignará con la hora segura del servidor al emitir.',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _dateTile(
    BuildContext context,
    String label,
    DateTime date,
    VoidCallback onTap,
  ) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: isDark
              ? Colors.white.withValues(alpha: 0.04)
              : Colors.grey.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          children: [
            Icon(
              Icons.calendar_month,
              color: isDark ? Colors.grey[400] : Colors.grey[600],
              size: 20,
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 12,
                      color: isDark ? Colors.grey[400] : Colors.grey[600],
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    DateFormat('dd/MM/yyyy HH:mm').format(date),
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right, size: 20, color: Colors.grey),
          ],
        ),
      ),
    );
  }

  Widget _text(
    BuildContext context,
    TextEditingController controller,
    String label, {
    String? hint,
    int maxLines = 1,
  }) {
    return TextField(
      controller: controller,
      maxLines: maxLines,
      decoration: _input(context, label, Icons.edit).copyWith(hintText: hint),
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
