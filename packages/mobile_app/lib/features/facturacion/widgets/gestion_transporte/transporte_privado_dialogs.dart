import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:core_logic/core_logic.dart';

Future<bool?> mostrarConductorDialog(
  BuildContext context,
  WidgetRef ref, [
  Map<String, dynamic>? item,
]) async {
  final partes = GreTransporteCatalogRules.separarNombreLegacy(
    item?['nombres']?.toString() ?? '',
    item?['apellidos']?.toString() ?? '',
  );
  final doc = TextEditingController(
    text: item?['numero_documento']?.toString() ?? '',
  );
  final nombres = TextEditingController(text: partes.nombres);
  final apellidos = TextEditingController(text: partes.apellidos);
  final licencia = TextEditingController(
    text: item?['numero_licencia']?.toString() ?? '',
  );
  bool consultando = false;

  final result = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (dialogContext, setDialogState) => AlertDialog(
        title: Text(item == null ? 'Nuevo conductor' : 'Editar conductor'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: doc,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: 'DNI',
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
                            final value = doc.text.trim();
                            if (!GreTransporteCatalogRules.dniValido(value)) {
                              return;
                            }
                            setDialogState(() => consultando = true);
                            try {
                              final data = await ref
                                  .read(personaLookupRepositoryProvider)
                                  .consultar(numero: value, tipo: 'dni');
                              if (data == null || !dialogContext.mounted)
                                return;

                              var nombresApi =
                                  data['nombres']?.toString().trim() ?? '';
                              var apellidosApi = [
                                data['apellido_paterno']?.toString().trim() ??
                                    '',
                                data['apellido_materno']?.toString().trim() ??
                                    '',
                              ].where((value) => value.isNotEmpty).join(' ');

                              if (nombresApi.isEmpty) {
                                final completo =
                                    data['nombre_completo']
                                        ?.toString()
                                        .trim() ??
                                    '';
                                final parsed =
                                    GreTransporteCatalogRules.separarNombreLegacy(
                                      completo,
                                      '',
                                    );
                                nombresApi = parsed.nombres;
                                if (apellidosApi.isEmpty) {
                                  apellidosApi = parsed.apellidos;
                                }
                              }

                              setDialogState(() {
                                if (nombresApi.isNotEmpty)
                                  nombres.text = nombresApi;
                                if (apellidosApi.isNotEmpty) {
                                  apellidos.text = apellidosApi;
                                }
                              });
                            } catch (e, st) {
                              debugPrint(
                                'TransportePrivadoDialogs: fallo consulta DNI: $e',
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
                controller: nombres,
                decoration: const InputDecoration(
                  labelText: 'Nombres',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: apellidos,
                decoration: const InputDecoration(
                  labelText: 'Apellidos',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: licencia,
                decoration: const InputDecoration(
                  labelText: 'Número de licencia',
                  helperText: 'Obligatorio para transporte privado.',
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
              if (!GreTransporteCatalogRules.conductorValido(
                dni: doc.text,
                nombres: nombres.text,
                apellidos: apellidos.text,
                licencia: licencia.text,
              )) {
                ScaffoldMessenger.of(dialogContext).showSnackBar(
                  const SnackBar(
                    content: Text(
                      'Completa DNI, nombres, apellidos y licencia reales.',
                    ),
                    backgroundColor: Colors.red,
                  ),
                );
                return;
              }
              try {
                await ref
                    .read(guiasRemisionRepositoryProvider)
                    .guardarConductor(
                      id: (item?['id'] as num?)?.toInt(),
                      tipoDocumento: '1',
                      numeroDocumento: doc.text.trim(),
                      nombres: nombres.text.trim(),
                      apellidos: apellidos.text.trim(),
                      licencia: licencia.text.trim(),
                    );
                if (dialogContext.mounted) Navigator.pop(dialogContext, true);
              } catch (e, st) {
                debugPrint(
                  'TransportePrivadoDialogs: fallo guardar conductor: $e',
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
    doc.dispose();
    nombres.dispose();
    apellidos.dispose();
    licencia.dispose();
  });
  return result;
}

Future<bool?> mostrarVehiculoDialog(
  BuildContext context,
  WidgetRef ref, [
  Map<String, dynamic>? item,
]) async {
  final placa = TextEditingController(text: item?['placa']?.toString() ?? '');
  final marca = TextEditingController(text: item?['marca']?.toString() ?? '');
  final modelo = TextEditingController(text: item?['modelo']?.toString() ?? '');
  final constancia = TextEditingController(
    text: item?['constancia_inscripcion']?.toString() ?? '',
  );

  final result = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(item == null ? 'Nuevo vehículo' : 'Editar vehículo'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: placa,
              decoration: const InputDecoration(
                labelText: 'Placa',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: marca,
              decoration: const InputDecoration(
                labelText: 'Marca',
                helperText: 'Obligatoria para transporte privado.',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: modelo,
              decoration: const InputDecoration(
                labelText: 'Modelo (opcional)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: constancia,
              decoration: const InputDecoration(
                labelText: 'Constancia / habilitación vehicular',
                helperText: 'Número real de constancia, certificado o TUC.',
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
            if (!GreTransporteCatalogRules.vehiculoValido(
              placa: placa.text,
              marca: marca.text,
              constancia: constancia.text,
            )) {
              ScaffoldMessenger.of(dialogContext).showSnackBar(
                const SnackBar(
                  content: Text(
                    'Completa placa, marca y constancia vehicular reales.',
                  ),
                  backgroundColor: Colors.red,
                ),
              );
              return;
            }
            try {
              await ref
                  .read(guiasRemisionRepositoryProvider)
                  .guardarVehiculo(
                    id: (item?['id'] as num?)?.toInt(),
                    placa: placa.text.trim().toUpperCase(),
                    marca: marca.text.trim(),
                    modelo: modelo.text.trim(),
                    constanciaInscripcion: constancia.text.trim(),
                  );
              if (dialogContext.mounted) Navigator.pop(dialogContext, true);
            } catch (e, st) {
              debugPrint(
                'TransportePrivadoDialogs: fallo guardar vehículo: $e',
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
  );

  Future<void>.delayed(const Duration(milliseconds: 400), () {
    placa.dispose();
    marca.dispose();
    modelo.dispose();
    constancia.dispose();
  });
  return result;
}
