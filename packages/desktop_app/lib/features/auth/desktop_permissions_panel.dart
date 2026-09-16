import 'package:core_logic/core_logic.dart';
import 'package:core_logic/auth/application/employee_directory_use_case.dart';
import 'package:core_logic/auth/data/supabase_employee_directory_gateway.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

final desktopEmployeeDirectoryProvider = FutureProvider.autoDispose
    .family<List<EmployeeDirectoryRecord>, bool>((ref, includeInactive) {
      return EmployeeDirectoryUseCase(
        SupabaseEmployeeDirectoryGateway(Supabase.instance.client),
      ).list(includeInactive: includeInactive);
    });

class DesktopPermissionsPanel extends ConsumerStatefulWidget {
  const DesktopPermissionsPanel({super.key});

  @override
  ConsumerState<DesktopPermissionsPanel> createState() =>
      _DesktopPermissionsPanelState();
}

class _DesktopPermissionsPanelState
    extends ConsumerState<DesktopPermissionsPanel> {
  bool _includeInactive = false;

  String _label(AppPermission permission) => switch (permission) {
    AppPermission.productsCreate => 'Crear productos',
    AppPermission.productsUpdate => 'Editar productos',
    AppPermission.productsChangePrice => 'Cambiar precios',
    AppPermission.inventoryReceive => 'Registrar ingresos de inventario',
    AppPermission.inventoryAdjust => 'Ajustar, trasladar o registrar merma',
    AppPermission.salesCreate => 'Registrar ventas',
    AppPermission.salesDiscount => 'Aplicar descuentos',
    AppPermission.purchasesManage => 'Gestionar órdenes de compra',
    AppPermission.reportsViewProfit => 'Ver utilidad en reportes',
    AppPermission.businessConfigure => 'Configurar negocio',
  };

  Future<void> _edit(EmployeeDirectoryRecord employee) async {
    try {
      final useCase = ref.read(manageEmployeePermissionsUseCaseProvider);
      var current = await useCase.load(employee.id);
      if (!mounted) return;
      if (current.isAdministrator) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'El administrador conserva todos los permisos por definición del rol.',
            ),
          ),
        );
        return;
      }

      final values = <AppPermission, bool>{
        for (final row in current.permissions) row.permission: row.allowed,
      };
      final saved = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(
          builder: (context, setDialogState) => AlertDialog(
            title: Text('Permisos · ${employee.name}'),
            content: SizedBox(
              width: 620,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'Rol base: ${employee.role}. Sólo puedes restringir permisos que el rol ya posee; esta pantalla nunca eleva privilegios.',
                    ),
                    const SizedBox(height: 12),
                    ...current.permissions.map((setting) {
                      final permittedByRole = setting.baseAllowed;
                      return SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(_label(setting.permission)),
                        subtitle: Text(
                          permittedByRole
                              ? setting.permission.code
                              : '${setting.permission.code} · no concedido por el rol',
                        ),
                        value: values[setting.permission] ?? false,
                        onChanged: permittedByRole
                            ? (value) => setDialogState(
                                () => values[setting.permission] = value,
                              )
                            : null,
                      );
                    }),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('Cancelar'),
              ),
              FilledButton(
                onPressed: () async {
                  try {
                    current = await useCase.save(current, values);
                    if (dialogContext.mounted) {
                      Navigator.pop(dialogContext, true);
                    }
                  } catch (error) {
                    if (!dialogContext.mounted) return;
                    ScaffoldMessenger.of(dialogContext).showSnackBar(
                      SnackBar(content: Text(ErrorMapper.map(error))),
                    );
                  }
                },
                child: const Text('Guardar permisos'),
              ),
            ],
          ),
        ),
      );
      if (saved == true && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Permisos actualizados. Se aplicarán en la siguiente revalidación de sesión.',
            ),
          ),
        );
      }
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(ErrorMapper.map(error))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final employees = ref.watch(
      desktopEmployeeDirectoryProvider(_includeInactive),
    );
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(28, 24, 28, 16),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Permisos',
                      style: Theme.of(context).textTheme.headlineMedium
                          ?.copyWith(fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 5),
                    const Text(
                      'Overrides restrictivos por empleado sobre la matriz base del rol.',
                    ),
                  ],
                ),
              ),
              FilterChip(
                label: const Text('Incluir inactivos'),
                selected: _includeInactive,
                onSelected: (value) => setState(() => _includeInactive = value),
              ),
            ],
          ),
        ),
        Expanded(
          child: employees.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (error, _) => Center(child: Text(ErrorMapper.map(error))),
            data: (rows) => rows.isEmpty
                ? const Center(child: Text('No hay empleados para mostrar.'))
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(28, 0, 28, 28),
                    itemCount: rows.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (context, index) {
                      final employee = rows[index];
                      return Card(
                        child: ListTile(
                          leading: CircleAvatar(
                            child: Text(
                              employee.name.characters.first.toUpperCase(),
                            ),
                          ),
                          title: Text(employee.name),
                          subtitle: Text(
                            [
                              employee.role,
                              employee.active ? 'Activo' : 'Inactivo',
                              if (employee.position?.isNotEmpty == true)
                                employee.position!,
                              if (employee.email?.isNotEmpty == true)
                                employee.email!,
                            ].join(' · '),
                          ),
                          trailing: FilledButton.tonalIcon(
                            onPressed: employee.active
                                ? () => _edit(employee)
                                : null,
                            icon: const Icon(
                              Icons.admin_panel_settings_outlined,
                            ),
                            label: const Text('Permisos'),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ),
      ],
    );
  }
}
