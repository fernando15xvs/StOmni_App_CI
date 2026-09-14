import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import 'package:core_logic/core_logic.dart';

class SolicitarBajaTributariaPage extends ConsumerStatefulWidget {
  final String tipoOrigen;
  final String origenId;
  final String numeroDocumento;
  final String? tipoProcesoEsperado;

  const SolicitarBajaTributariaPage({
    super.key,
    required this.tipoOrigen,
    required this.origenId,
    required this.numeroDocumento,
    this.tipoProcesoEsperado,
  });

  @override
  ConsumerState<SolicitarBajaTributariaPage> createState() =>
      _SolicitarBajaTributariaPageState();
}

class _SolicitarBajaTributariaPageState
    extends ConsumerState<SolicitarBajaTributariaPage> {
  final _formKey = GlobalKey<FormState>();
  final _motivoCtrl = TextEditingController();
  final String _requestId = const Uuid().v4();
  bool _procesando = false;

  @override
  void dispose() {
    _motivoCtrl.dispose();
    super.dispose();
  }

  Future<void> _solicitar() async {
    if (_procesando || !_formKey.currentState!.validate()) return;
    FocusScope.of(context).unfocus();
    setState(() => _procesando = true);

    try {
      await ref
          .read(procesosTributariosRepositoryProvider)
          .solicitarBaja(
            requestId: _requestId,
            tipoOrigen: widget.tipoOrigen,
            origenId: widget.origenId,
            motivo: _motivoCtrl.text.trim(),
          );

      if (!mounted) return;
      Navigator.pop(context, true);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Solicitud registrada. Quedó pendiente de revisión y procesamiento manual por un administrador.',
          ),
          backgroundColor: Colors.green,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(e.toString().replaceFirst('Exception: ', '')),
          backgroundColor: Colors.red,
        ),
      );
    } finally {
      if (mounted) setState(() => _procesando = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final color = Colors.deepPurple;
    final esNota = widget.tipoOrigen == 'nota_credito';

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        title: const Text(
          'Comunicar baja tributaria',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        backgroundColor: color,
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(18),
          children: [
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: Theme.of(context).cardColor,
                borderRadius: BorderRadius.circular(18),
                boxShadow: Theme.of(context).brightness == Brightness.dark
                    ? null
                    : const [
                        BoxShadow(
                          color: Color(0x12000000),
                          blurRadius: 16,
                          offset: Offset(0, 6),
                        ),
                      ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.numeroDocumento,
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    widget.tipoProcesoEsperado == 'resumen_boletas'
                        ? 'Se comunicará mediante Resumen Diario.'
                        : 'Se comunicará mediante Comunicación de Baja.',
                    style: TextStyle(color: Colors.grey.shade700),
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: _motivoCtrl,
                    textCapitalization: TextCapitalization.sentences,
                    maxLength: 250,
                    maxLines: 4,
                    decoration: const InputDecoration(
                      labelText: 'Motivo de la baja',
                      hintText: 'Ejemplo: error en la emisión del documento',
                      border: OutlineInputBorder(),
                      alignLabelWithHint: true,
                    ),
                    validator: (value) {
                      final text = value?.trim() ?? '';
                      if (text.length < 3) {
                        return 'Escribe un motivo de al menos 3 caracteres.';
                      }
                      return null;
                    },
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Theme.of(context).brightness == Brightness.dark
                    ? Colors.orange.withValues(alpha: 0.1)
                    : Colors.orange.shade50,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: Theme.of(context).brightness == Brightness.dark
                      ? Colors.orange.withValues(alpha: 0.3)
                      : Colors.orange.shade200,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Row(
                    children: [
                      Icon(Icons.warning_amber_rounded, color: Colors.orange),
                      SizedBox(width: 8),
                      Text(
                        'Operación tributaria',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Text(
                    esNota
                        ? 'La nota permanecerá en el historial. Cuando SUNAT acepte la baja, el sistema revertirá su efecto local de stock y recalculará la venta.'
                        : 'El comprobante y la venta permanecerán en el historial. Esta acción no devuelve stock ni elimina pagos. Para una devolución comercial corresponde emitir una nota de crédito.',
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: _procesando ? null : _solicitar,
              icon: _procesando
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.cloud_off_rounded, color: Colors.white),
              label: Text(
                _procesando ? 'PROCESANDO...' : 'SOLICITAR BAJA',
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                ),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red.shade700,
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
