import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import 'package:core_logic/core_logic.dart';
import '../presentation/controllers/almacen_admin_controller.dart';

class ConfigAlmacenesPage extends ConsumerWidget {
  const ConfigAlmacenesPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncState = ref.watch(almacenAdminNotifierProvider);
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: isDark
          ? const Color(0xFF121212)
          : Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        title: const Text(
          'Configurar almacenes',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        backgroundColor: AppColors.almacenes,
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: asyncState.when(
        loading: () =>
            Center(child: CircularProgressIndicator(color: AppColors.almacenes)),
        error: (err, _) => Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(ErrorMapper.map(err)),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: () => ref.invalidate(almacenAdminNotifierProvider),
                icon: const Icon(Icons.refresh),
                label: const Text('Reintentar'),
              ),
            ],
          ),
        ),
        data: (almacenes) => almacenes.isEmpty
            ? const Center(child: Text('No hay almacenes registrados.'))
            : RefreshIndicator(
                onRefresh: () => ref
                    .read(almacenAdminNotifierProvider.notifier)
                    .recargar(),
                child: ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
                  itemCount: almacenes.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 12),
                  itemBuilder: (_, index) {
                    final almacen = almacenes[index];
                    final activo = almacen['activo'] == true;
                    final completo =
                        (almacen['direccion']?.toString().trim().isNotEmpty ??
                                false) &&
                            RegExp(
                              r'^[0-9]{6}$',
                            ).hasMatch(almacen['ubigeo']?.toString() ?? '');

                    return Opacity(
                      opacity: activo ? 1 : 0.68,
                      child: Material(
                        color: isDark
                            ? const Color(0xFF1E1E1E)
                            : Theme.of(context).cardColor,
                        borderRadius: BorderRadius.circular(18),
                        elevation: 1,
                        child: ListTile(
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 10,
                          ),
                          leading: CircleAvatar(
                            backgroundColor: (activo
                                    ? AppColors.almacenes
                                    : Colors.grey)
                                .withValues(alpha: 0.12),
                            child: Icon(
                              activo
                                  ? Icons.storefront
                                  : Icons.storefront_outlined,
                              color: activo ? AppColors.almacenes : Colors.grey,
                            ),
                          ),
                          title: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  almacen['nombre']?.toString() ?? '',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w900,
                                  ),
                                ),
                              ),
                              if (!activo)
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 3,
                                  ),
                                  decoration: BoxDecoration(
                                    color: Colors.grey.withValues(alpha: 0.15),
                                    borderRadius: BorderRadius.circular(999),
                                  ),
                                  child: const Text(
                                    'INACTIVO',
                                    style: TextStyle(
                                      fontSize: 10,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                          subtitle: Text(
                            completo
                                ? '${almacen['direccion']}\n'
                                      'Ubigeo: ${almacen['ubigeo']}'
                                : 'Falta dirección o ubigeo para emitir GRE',
                            style: TextStyle(
                              color: completo
                                  ? (isDark
                                        ? Colors.grey.shade400
                                        : Colors.grey.shade700)
                                  : (isDark
                                        ? Colors.orange.shade300
                                        : Colors.orange.shade800),
                            ),
                          ),
                          isThreeLine: true,
                          trailing: PopupMenuButton<String>(
                            onSelected: (value) {
                              if (value == 'editar') {
                                _mostrarFormulario(context, ref, almacen);
                              }
                              if (value == 'desactivar') {
                                _desactivar(context, ref, almacen);
                              }
                              if (value == 'reactivar') {
                                _reactivar(context, ref, almacen);
                              }
                            },
                            itemBuilder: (_) => [
                              const PopupMenuItem(
                                value: 'editar',
                                child: ListTile(
                                  contentPadding: EdgeInsets.zero,
                                  leading: Icon(Icons.edit),
                                  title: Text('Editar'),
                                ),
                              ),
                              if (activo)
                                const PopupMenuItem(
                                  value: 'desactivar',
                                  child: ListTile(
                                    contentPadding: EdgeInsets.zero,
                                    leading: Icon(
                                      Icons.block_outlined,
                                      color: Colors.red,
                                    ),
                                    title: Text('Desactivar'),
                                  ),
                                )
                              else
                                const PopupMenuItem(
                                  value: 'reactivar',
                                  child: ListTile(
                                    contentPadding: EdgeInsets.zero,
                                    leading: Icon(
                                      Icons.restore,
                                      color: Colors.green,
                                    ),
                                    title: Text('Reactivar'),
                                  ),
                                ),
                            ],
                          ),
                          onTap: () =>
                              _mostrarFormulario(context, ref, almacen),
                        ),
                      ),
                    );
                  },
                ),
              ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _mostrarFormulario(context, ref, null),
        backgroundColor: AppColors.almacenes,
        icon: const Icon(Icons.add_business, color: Colors.white),
        label: const Text(
          'NUEVO ALMACÉN',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Métodos de acción — la vista solo orquesta diálogos y delega al notifier
  // ---------------------------------------------------------------------------

  Future<void> _mostrarFormulario(
    BuildContext context,
    WidgetRef ref,
    Map<String, dynamic>? almacen,
  ) async {
    final formKey = GlobalKey<FormState>();
    final nombre = TextEditingController(
      text: almacen?['nombre']?.toString() ?? '',
    );
    final direccion = TextEditingController(
      text: almacen?['direccion']?.toString() ?? '',
    );
    final ubigeo = TextEditingController(
      text: almacen?['ubigeo']?.toString() ?? '',
    );
    final departamento = TextEditingController(
      text: almacen?['departamento']?.toString() ?? '',
    );
    final provincia = TextEditingController(
      text: almacen?['provincia']?.toString() ?? '',
    );
    final distrito = TextEditingController(
      text: almacen?['distrito']?.toString() ?? '',
    );
    final codLocal = TextEditingController(
      text: almacen?['cod_local']?.toString() ?? '0000',
    );
    final referencia = TextEditingController(
      text: almacen?['referencia']?.toString() ?? '',
    );

    final guardar = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(almacen == null ? 'Nuevo almacén' : 'Editar almacén'),
        content: SizedBox(
          width: 560,
          child: Form(
            key: formKey,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _campo(nombre, 'Nombre del almacén', Icons.storefront,
                      requerido: true),
                  const SizedBox(height: 10),
                  _campo(
                    direccion,
                    'Dirección completa',
                    Icons.location_on_outlined,
                    requerido: true,
                    maxLines: 2,
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: _campo(
                          ubigeo,
                          'Ubigeo',
                          Icons.pin_drop_outlined,
                          requerido: true,
                          keyboardType: TextInputType.number,
                          validator: (value) {
                            final text = value?.trim() ?? '';
                            if (!RegExp(r'^[0-9]{6}$').hasMatch(text)) {
                              return 'Debe tener 6 dígitos';
                            }
                            return null;
                          },
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _campo(codLocal, 'Código local', Icons.tag,
                            requerido: true),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  _campo(departamento, 'Departamento', Icons.map_outlined,
                      requerido: true),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: _campo(provincia, 'Provincia', Icons.map,
                            requerido: true),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _campo(
                          distrito,
                          'Distrito',
                          Icons.location_city,
                          requerido: true,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  _campo(
                    referencia,
                    'Referencia (opcional)',
                    Icons.signpost_outlined,
                    maxLines: 2,
                  ),
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.blue.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Text(
                      'La dirección y el ubigeo se usarán como punto de '
                      'partida o llegada en las guías de remisión.',
                      style: TextStyle(fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          ElevatedButton(
            onPressed: () {
              if (formKey.currentState?.validate() == true) {
                Navigator.pop(ctx, true);
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.almacenes,
            ),
            child: const Text('GUARDAR',
                style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );

    // Limpieza de controladores independiente del resultado.
    void disposeAll() {
      nombre.dispose();
      direccion.dispose();
      ubigeo.dispose();
      departamento.dispose();
      provincia.dispose();
      distrito.dispose();
      codLocal.dispose();
      referencia.dispose();
    }

    if (guardar != true) {
      disposeAll();
      return;
    }

    try {
      await ref.read(almacenAdminNotifierProvider.notifier).guardar(
            id: (almacen?['id'] as num?)?.toInt(),
            nombre: nombre.text,
            direccion: direccion.text,
            ubigeo: ubigeo.text,
            departamento: departamento.text,
            provincia: provincia.text,
            distrito: distrito.text,
            codLocal: codLocal.text,
            referencia: referencia.text,
          );
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Almacén guardado correctamente.'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.toString()), backgroundColor: Colors.red),
        );
      }
    } finally {
      disposeAll();
    }
  }

  Future<void> _desactivar(
    BuildContext context,
    WidgetRef ref,
    Map<String, dynamic> almacen,
  ) async {
    final confirmar = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('¿Desactivar almacén?'),
        content: Text(
          '"${almacen['nombre']}" dejará de estar disponible para nuevas '
          'operaciones, pero sus ventas, movimientos, Kardex y documentos '
          'históricos se conservarán.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('DESACTIVAR',
                style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (confirmar != true) return;
    try {
      await ref
          .read(almacenAdminNotifierProvider.notifier)
          .desactivar((almacen['id'] as num).toInt());
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Almacén desactivado. El historial se conservó.'),
            backgroundColor: Colors.orange,
          ),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.toString()), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _reactivar(
    BuildContext context,
    WidgetRef ref,
    Map<String, dynamic> almacen,
  ) async {
    final confirmar = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('¿Reactivar almacén?'),
        content: Text(
          '"${almacen['nombre']}" volverá a estar disponible para nuevas operaciones.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('REACTIVAR',
                style: TextStyle(color: Colors.green)),
          ),
        ],
      ),
    );

    if (confirmar != true) return;
    try {
      await ref
          .read(almacenAdminNotifierProvider.notifier)
          .reactivar((almacen['id'] as num).toInt());
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Almacén reactivado correctamente.'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.toString()), backgroundColor: Colors.red),
        );
      }
    }
  }

  Widget _campo(
    TextEditingController controller,
    String label,
    IconData icon, {
    bool requerido = false,
    int maxLines = 1,
    TextInputType? keyboardType,
    String? Function(String?)? validator,
  }) {
    return TextFormField(
      controller: controller,
      maxLines: maxLines,
      keyboardType: keyboardType,
      textCapitalization: TextCapitalization.characters,
      decoration: InputDecoration(
        labelText: label,
        prefixIcon: Icon(icon),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
      ),
      validator:
          validator ??
          (value) {
            if (requerido && (value?.trim().isEmpty ?? true)) {
              return 'Campo obligatorio';
            }
            return null;
          },
    );
  }
}
