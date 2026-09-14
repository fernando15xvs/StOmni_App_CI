import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import 'package:core_logic/core_logic.dart';
import '../../../core/widgets/app_form_styles.dart';
import '../providers/customer_use_case_provider.dart';

class ClienteFormDialog extends ConsumerStatefulWidget {
  final CustomerRecord? cliente;
  final VoidCallback onSaved;

  const ClienteFormDialog({super.key, this.cliente, required this.onSaved});

  @override
  ConsumerState<ClienteFormDialog> createState() => _ClienteFormDialogState();
}

class _ClienteFormDialogState extends ConsumerState<ClienteFormDialog> {
  late final TextEditingController docCtrl;
  late final TextEditingController nombreCtrl;
  final paternoCtrl = TextEditingController();
  final maternoCtrl = TextEditingController();
  late final TextEditingController dirCtrl;

  bool _consultando = false;
  bool _guardando = false;
  String? _estadoSunat;
  String? _condicionSunat;

  @override
  void initState() {
    super.initState();
    docCtrl = TextEditingController(text: widget.cliente?.document ?? '');
    nombreCtrl = TextEditingController(text: widget.cliente?.name ?? '');
    dirCtrl = TextEditingController(text: widget.cliente?.address ?? '');
  }

  @override
  void dispose() {
    docCtrl.dispose();
    nombreCtrl.dispose();
    paternoCtrl.dispose();
    maternoCtrl.dispose();
    dirCtrl.dispose();
    super.dispose();
  }

  Future<void> _consultarDocumento() async {
    final doc = docCtrl.text.trim();
    if (doc.isEmpty || (doc.length != 8 && doc.length != 11)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('El RUC/DNI debe tener 8 u 11 dígitos'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    setState(() {
      _consultando = true;
      _estadoSunat = null;
      _condicionSunat = null;
    });

    try {
      final tipo = doc.length == 8 ? 'dni' : 'ruc';
      final data = await ref
          .read(personaLookupRepositoryProvider)
          .consultar(numero: doc, tipo: tipo);

      if (data != null && mounted) {
        setState(() {
          if (tipo == 'dni') {
            nombreCtrl.text = data['nombres'] ?? '';
            paternoCtrl.text = data['apellido_paterno'] ?? '';
            maternoCtrl.text = data['apellido_materno'] ?? '';
          } else {
            nombreCtrl.text = data['razon_social'] ?? '';
            paternoCtrl.clear();
            maternoCtrl.clear();
          }

          final apiData = data['data'];
          if (apiData is Map) {
            if (apiData['direccion'] != null &&
                apiData['direccion'].toString().trim().isNotEmpty) {
              dirCtrl.text = apiData['direccion'].toString();
            }
            if (apiData['estado'] != null) {
              _estadoSunat = apiData['estado'].toString();
            }
            if (apiData['condicion'] != null) {
              _condicionSunat = apiData['condicion'].toString();
            }
          }
        });
      }
    } catch (e) {
      _mostrarError(e);
    } finally {
      if (mounted) {
        setState(() => _consultando = false);
      }
    }
  }

  Future<void> _guardar() async {
    if (_guardando) return;

    final esRuc = docCtrl.text.trim().length == 11;
    final nombreFinal = [
      nombreCtrl.text.trim(),
      if (!esRuc) paternoCtrl.text.trim(),
      if (!esRuc) maternoCtrl.text.trim(),
    ].where((e) => e.isNotEmpty).join(' ');

    if (nombreFinal.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('El nombre es obligatorio'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    final dniRuc = docCtrl.text.trim().isEmpty
        ? '00000000'
        : docCtrl.text.trim();

    setState(() => _guardando = true);

    try {
      await ref.read(customerUseCaseProvider).save(
            CustomerDraft(
              name: nombreFinal,
              document: dniRuc,
              address: dirCtrl.text.trim().isEmpty ? '-' : dirCtrl.text.trim(),
              documentType: dniRuc.length == 8
                  ? '1'
                  : (dniRuc.length == 11 ? '6' : null),
            ),
            id: widget.cliente?.id,
          );

      if (!mounted) return;
      Navigator.pop(context);
      widget.onSaved();
    } catch (e) {
      _mostrarError(e);
    } finally {
      if (mounted) setState(() => _guardando = false);
    }
  }

  void _mostrarError(Object error) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(ErrorMapper.map(error)),
        backgroundColor: Colors.red,
        duration: const Duration(seconds: 4),
      ),
    );
  }

  Widget _inputDecor(
    BuildContext context,
    TextEditingController ctrl,
    String label,
    IconData icon, {
    bool number = false,
    void Function(String)? onChanged,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return TextField(
      controller: ctrl,
      keyboardType: number ? TextInputType.number : TextInputType.text,
      onChanged: onChanged,
      style: TextStyle(color: isDark ? Colors.white : Colors.black87),
      decoration: AppFormStyles.inputDecor(
        context,
        label,
        icon: icon,
        primaryColor: AppColors.clientes,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final esRuc = docCtrl.text.trim().length == 11;

    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      title: Text(widget.cliente == null ? 'Nuevo Cliente' : 'Editar Cliente'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: _inputDecor(
                    context,
                    docCtrl,
                    'RUC / DNI *',
                    Icons.badge,
                    number: true,
                    onChanged: (_) => setState(() {}),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  onPressed: _consultando || _guardando
                      ? null
                      : _consultarDocumento,
                  icon: _consultando
                      ? const SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.search),
                  color: AppColors.clientes,
                  tooltip: 'Consultar en SUNAT/RENIEC',
                ),
              ],
            ),
            const SizedBox(height: 10),
            if (esRuc)
              _inputDecor(context, nombreCtrl, 'Razón Social *', Icons.business)
            else if (widget.cliente != null &&
                paternoCtrl.text.isEmpty &&
                maternoCtrl.text.isEmpty)
              _inputDecor(
                context,
                nombreCtrl,
                'Nombre Completo *',
                Icons.person,
              )
            else ...[
              _inputDecor(context, nombreCtrl, 'Nombres *', Icons.person),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: _inputDecor(
                      context,
                      paternoCtrl,
                      'Ap. Paterno',
                      Icons.person_outline,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _inputDecor(
                      context,
                      maternoCtrl,
                      'Ap. Materno',
                      Icons.person_outline,
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 10),
            if (_estadoSunat != null || _condicionSunat != null)
              Container(
                padding: const EdgeInsets.all(10),
                margin: const EdgeInsets.only(bottom: 10),
                decoration: BoxDecoration(
                  color: Colors.blue.shade50,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (_estadoSunat != null)
                      Text(
                        'Estado SUNAT: $_estadoSunat',
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          color: Colors.blueGrey,
                        ),
                      ),
                    if (_condicionSunat != null)
                      Text(
                        'Condición: $_condicionSunat',
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          color: Colors.blueGrey,
                        ),
                      ),
                  ],
                ),
              ),
            _inputDecor(context, dirCtrl, 'Dirección', Icons.location_on),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _guardando ? null : () => Navigator.pop(context),
          child: Text(
            'Cancelar',
            style: TextStyle(
              color: Theme.of(context).brightness == Brightness.dark
                  ? Colors.grey[300]
                  : Colors.grey[800],
            ),
          ),
        ),
        ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.clientes,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
          ),
          onPressed: _guardando ? null : _guardar,
          child: _guardando
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : const Text(
                  'Guardar',
                  style: TextStyle(color: Colors.white),
                ),
        ),
      ],
    );
  }
}
