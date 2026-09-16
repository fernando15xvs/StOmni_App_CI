import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:core_logic/core_logic.dart';

Future<bool?> mostrarTransportistaDialog(
  BuildContext context,
  WidgetRef ref, [
  Map<String, dynamic>? item,
]) async {
  final ruc = TextEditingController(text: item?['ruc']?.toString() ?? '');
  final razonSocial = TextEditingController(
    text: item?['razon_social']?.toString() ?? '',
  );
  final mtc = TextEditingController(
    text: item?['registro_mtc']?.toString() ?? '',
  );
  bool consultando = false;

  final result = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (dialogContext, setDialogState) => AlertDialog(
        title: Text(
          item == null ? 'Nuevo transportista' : 'Editar transportista',
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: ruc,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: 'RUC',
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    icon: consultando
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.search),
                    onPressed: consultando
                        ? null
                        : () async {
                            final value = ruc.text.trim();
                            if (!GreTransporteCatalogRules.rucValido(value)) {
                              return;
                            }
                            setDialogState(() => consultando = true);
                            try {
                              final data = await ref
                                  .read(personaLookupRepositoryProvider)
                                  .consultar(numero: value, tipo: 'ruc');
                              if (data != null && dialogContext.mounted) {
                                setDialogState(() {
                                  razonSocial.text =
                                      data['razon_social']?.toString() ?? '';
                                });
                              }
                            } catch (e, st) {
                              debugPrint(
                                'TransportePublicoDialogs: fallo consulta RUC: $e',
                              );
                              debugPrintStack(stackTrace: st);
                              if (dialogContext.mounted) {
                                ScaffoldMessenger.of(
                                  dialogContext,
                                ).showSnackBar(
                                  SnackBar(
                                    content: Text(ErrorMapper.map(e)),
                                    backgroundColor: Colors.red,
                                  ),
                                );
                              }
                            } finally {
                              if (dialogContext.mounted) {
                                setDialogState(() => consultando = false);
                              }
                            }
                          },
                  ),
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: razonSocial,
                decoration: const InputDecoration(
                  labelText: 'Razón social',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: mtc,
                decoration: const InputDecoration(
                  labelText: 'Registro MTC (opcional)',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancelar'),
          ),
          ElevatedButton(
            onPressed: () async {
              if (!GreTransporteCatalogRules.transportistaValido(
                ruc: ruc.text,
                razonSocial: razonSocial.text,
              )) {
                ScaffoldMessenger.of(dialogContext).showSnackBar(
                  const SnackBar(
                    content: Text('Ingresa un RUC válido y la razón social.'),
                    backgroundColor: Colors.red,
                  ),
                );
                return;
              }
              try {
                await ref
                    .read(guiasRemisionRepositoryProvider)
                    .guardarTransportista(
                      id: (item?['id'] as num?)?.toInt(),
                      ruc: ruc.text.trim(),
                      razonSocial: razonSocial.text.trim(),
                      registroMtc: mtc.text.trim(),
                    );
                if (dialogContext.mounted) Navigator.pop(dialogContext, true);
              } catch (e, st) {
                debugPrint(
                  'TransportePublicoDialogs: fallo guardar transportista: $e',
                );
                debugPrintStack(stackTrace: st);
                if (dialogContext.mounted) {
                  ScaffoldMessenger.of(dialogContext).showSnackBar(
                    SnackBar(
                      content: Text(ErrorMapper.map(e)),
                      backgroundColor: Colors.red,
                    ),
                  );
                }
              }
            },
            child: const Text('GUARDAR'),
          ),
        ],
      ),
    ),
  );

  Future<void>.delayed(const Duration(milliseconds: 400), () {
    ruc.dispose();
    razonSocial.dispose();
    mtc.dispose();
  });
  return result;
}

Future<Map<String, dynamic>?> _buscarUbigeoExacto(
  WidgetRef ref,
  String codigo,
) async {
  final safe = codigo.trim();
  if (!GreTransporteCatalogRules.ubigeoValido(safe)) return null;
  final rows = await ref.read(greUbigeosRepositoryProvider).buscar(safe);
  for (final row in rows) {
    if (row['codigo']?.toString() == safe) return row;
  }
  return null;
}

Future<bool?> mostrarAgenciaDialog(
  BuildContext context,
  WidgetRef ref,
  Map<String, dynamic> transportista, [
  Map<String, dynamic>? item,
]) async {
  final nombre = TextEditingController(text: item?['nombre']?.toString() ?? '');
  final direccion = TextEditingController(
    text: item?['direccion']?.toString() ?? '',
  );
  final ubigeo = TextEditingController(text: item?['ubigeo']?.toString() ?? '');
  final departamento = TextEditingController(
    text: item?['departamento']?.toString() ?? '',
  );
  final provincia = TextEditingController(
    text: item?['provincia']?.toString() ?? '',
  );
  final distrito = TextEditingController(
    text: item?['distrito']?.toString() ?? '',
  );
  final telefono = TextEditingController(
    text: item?['telefono']?.toString() ?? '',
  );
  final codigoInterno = TextEditingController(
    text: item?['codigo_interno']?.toString() ?? '',
  );
  bool permiteOrigen = item?['permite_origen'] != false;
  bool permiteDestino = item?['permite_destino'] != false;
  bool consultandoUbigeo = false;

  final result = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (dialogContext, setDialogState) => AlertDialog(
        title: Text(item == null ? 'Nueva agencia' : 'Editar agencia'),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  transportista['razon_social']?.toString() ?? '',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: nombre,
                  decoration: const InputDecoration(
                    labelText: 'Nombre de la agencia',
                    hintText: 'Ej.: Lima - Av. México',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: direccion,
                  maxLines: 2,
                  decoration: const InputDecoration(
                    labelText: 'Dirección exacta',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: ubigeo,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: 'Ubigeo',
                    helperText: 'Código SUNAT de 6 dígitos.',
                    border: const OutlineInputBorder(),
                    suffixIcon: IconButton(
                      icon: consultandoUbigeo
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.search),
                      onPressed: consultandoUbigeo
                          ? null
                          : () async {
                              setDialogState(() => consultandoUbigeo = true);
                              try {
                                final row = await _buscarUbigeoExacto(
                                  ref,
                                  ubigeo.text,
                                );
                                if (row == null) {
                                  if (dialogContext.mounted) {
                                    ScaffoldMessenger.of(
                                      dialogContext,
                                    ).showSnackBar(
                                      const SnackBar(
                                        content: Text(
                                          'No se encontró un ubigeo activo.',
                                        ),
                                      ),
                                    );
                                  }
                                } else if (dialogContext.mounted) {
                                  setDialogState(() {
                                    departamento.text =
                                        row['departamento']?.toString() ?? '';
                                    provincia.text =
                                        row['provincia']?.toString() ?? '';
                                    distrito.text =
                                        row['distrito']?.toString() ?? '';
                                  });
                                }
                              } catch (e, st) {
                                debugPrint(
                                  'TransportePublicoDialogs: fallo buscar ubigeo: $e',
                                );
                                debugPrintStack(stackTrace: st);
                                if (dialogContext.mounted) {
                                  ScaffoldMessenger.of(
                                    dialogContext,
                                  ).showSnackBar(
                                    SnackBar(
                                      content: Text(ErrorMapper.map(e)),
                                      backgroundColor: Colors.red,
                                    ),
                                  );
                                }
                              } finally {
                                if (dialogContext.mounted) {
                                  setDialogState(
                                    () => consultandoUbigeo = false,
                                  );
                                }
                              }
                            },
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: departamento,
                  decoration: const InputDecoration(
                    labelText: 'Departamento',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: provincia,
                  decoration: const InputDecoration(
                    labelText: 'Provincia',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: distrito,
                  decoration: const InputDecoration(
                    labelText: 'Distrito',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: telefono,
                  decoration: const InputDecoration(
                    labelText: 'Teléfono (opcional)',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: codigoInterno,
                  decoration: const InputDecoration(
                    labelText: 'Código interno (opcional)',
                    border: OutlineInputBorder(),
                  ),
                ),
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Puede usarse como agencia de origen'),
                  value: permiteOrigen,
                  onChanged: (value) =>
                      setDialogState(() => permiteOrigen = value),
                ),
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Puede usarse como agencia de destino'),
                  value: permiteDestino,
                  onChanged: (value) =>
                      setDialogState(() => permiteDestino = value),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancelar'),
          ),
          ElevatedButton(
            onPressed: () async {
              if (!GreTransporteCatalogRules.agenciaValida(
                nombre: nombre.text,
                direccion: direccion.text,
                ubigeo: ubigeo.text,
                permiteOrigen: permiteOrigen,
                permiteDestino: permiteDestino,
              )) {
                ScaffoldMessenger.of(dialogContext).showSnackBar(
                  const SnackBar(
                    content: Text(
                      'Completa nombre, dirección, ubigeo y habilita al menos un uso.',
                    ),
                    backgroundColor: Colors.red,
                  ),
                );
                return;
              }
              try {
                final row = await _buscarUbigeoExacto(ref, ubigeo.text);
                if (row == null) {
                  throw const UserFacingException(
                    'El ubigeo no existe en el catálogo activo.',
                  );
                }
                await ref
                    .read(guiasRemisionRepositoryProvider)
                    .guardarAgencia(
                      id: (item?['id'] as num?)?.toInt(),
                      transportistaId: (transportista['id'] as num).toInt(),
                      nombre: nombre.text.trim(),
                      direccion: direccion.text.trim(),
                      ubigeo: ubigeo.text.trim(),
                      departamento: departamento.text.trim().isEmpty
                          ? row['departamento']?.toString()
                          : departamento.text.trim(),
                      provincia: provincia.text.trim().isEmpty
                          ? row['provincia']?.toString()
                          : provincia.text.trim(),
                      distrito: distrito.text.trim().isEmpty
                          ? row['distrito']?.toString()
                          : distrito.text.trim(),
                      telefono: telefono.text.trim(),
                      codigoInterno: codigoInterno.text.trim(),
                      permiteOrigen: permiteOrigen,
                      permiteDestino: permiteDestino,
                    );
                if (dialogContext.mounted) Navigator.pop(dialogContext, true);
              } catch (e, st) {
                debugPrint(
                  'TransportePublicoDialogs: fallo guardar agencia: $e',
                );
                debugPrintStack(stackTrace: st);
                if (dialogContext.mounted) {
                  ScaffoldMessenger.of(dialogContext).showSnackBar(
                    SnackBar(
                      content: Text(ErrorMapper.map(e)),
                      backgroundColor: Colors.red,
                    ),
                  );
                }
              }
            },
            child: const Text('GUARDAR'),
          ),
        ],
      ),
    ),
  );

  Future<void>.delayed(const Duration(milliseconds: 400), () {
    nombre.dispose();
    direccion.dispose();
    ubigeo.dispose();
    departamento.dispose();
    provincia.dispose();
    distrito.dispose();
    telefono.dispose();
    codigoInterno.dispose();
  });
  return result;
}
