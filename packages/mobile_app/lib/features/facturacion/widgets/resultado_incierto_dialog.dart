import 'package:flutter/material.dart';

import 'package:core_logic/core_logic.dart';

/// Abre una reconciliación administrativa segura.
///
/// Esta acción nunca marca un documento como aceptado. Solo permite mantenerlo
/// incierto o habilitar un nuevo intento después de verificar externamente que
/// SUNAT/APIsPERU no lo recibió.
Future<bool> mostrarReconciliacionResultadoIncierto({
  required BuildContext context,
  required String tipoDocumento,
  required String documentoId,
}) async {
  final motivoCtrl = TextEditingController();
  final referenciaCtrl = TextEditingController();
  String decision = 'mantener_incierto';

  final confirmar = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) => StatefulBuilder(
      builder: (dialogContext, setDialogState) => AlertDialog(
        title: const Text('Reconciliar resultado incierto'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Antes de habilitar otro envío, verifica en SUNAT o APIsPERU '
                'que el documento no haya sido recibido. Esta acción quedará '
                'registrada con tu usuario.',
              ),
              const SizedBox(height: 16),
              RadioGroup<String>(
                groupValue: decision,
                onChanged: (value) {
                  if (value != null) {
                    setDialogState(() => decision = value);
                  }
                },
                child: const Column(
                  children: [
                    RadioListTile<String>(
                      contentPadding: EdgeInsets.zero,
                      value: 'mantener_incierto',
                      title: Text('Mantener como incierto'),
                      subtitle: Text('No habilita ningún reenvío.'),
                    ),
                    RadioListTile<String>(
                      contentPadding: EdgeInsets.zero,
                      value: 'habilitar_reintento',
                      title: Text('Confirmar que no fue recibido'),
                      subtitle: Text(
                        'Habilita un reintento. Úsalo solo con evidencia externa.',
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: motivoCtrl,
                minLines: 3,
                maxLines: 5,
                maxLength: 500,
                decoration: const InputDecoration(
                  labelText: 'Cómo verificaste el estado',
                  hintText:
                      'Ej.: Consulté la serie y correlativo en SUNAT y no existe.',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: referenciaCtrl,
                maxLength: 200,
                decoration: const InputDecoration(
                  labelText: 'Referencia externa (opcional)',
                  hintText: 'Ticket de soporte, consulta o captura interna',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('CANCELAR'),
          ),
          FilledButton(
            onPressed: () {
              final motivo = motivoCtrl.text.trim();
              if (motivo.length < 10) {
                ScaffoldMessenger.of(dialogContext).showSnackBar(
                  const SnackBar(
                    content: Text(
                      'Describe la verificación con al menos 10 caracteres.',
                    ),
                  ),
                );
                return;
              }
              Navigator.pop(dialogContext, true);
            },
            child: const Text('REGISTRAR DECISIÓN'),
          ),
        ],
      ),
    ),
  );

  try {
    if (confirmar != true) return false;
    await FacturacionService.resolverResultadoIncierto(
      tipoDocumento: tipoDocumento,
      documentoId: documentoId,
      decision: decision,
      motivo: motivoCtrl.text.trim(),
      referenciaExterna: referenciaCtrl.text.trim(),
    );
    return true;
  } finally {
    motivoCtrl.dispose();
    referenciaCtrl.dispose();
  }
}
