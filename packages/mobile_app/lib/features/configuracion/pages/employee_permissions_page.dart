import 'package:core_logic/core_logic.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class EmployeePermissionsPage extends ConsumerStatefulWidget {
  const EmployeePermissionsPage({super.key});

  @override
  ConsumerState<EmployeePermissionsPage> createState() =>
      _EmployeePermissionsPageState();
}

class _EmployeePermissionsPageState
    extends ConsumerState<EmployeePermissionsPage> {
  List<Map<String, dynamic>> _employees = const [];
  int? _employeeId;
  EmployeePermissionSettings? _settings;
  Map<AppPermission, bool> _draft = const {};
  bool _loading = true;
  bool _saving = false;
  String? _error;

  static const _labels = <AppPermission, String>{
    AppPermission.productsCreate: 'Crear productos',
    AppPermission.productsUpdate: 'Editar productos',
    AppPermission.productsChangePrice: 'Cambiar precios',
    AppPermission.inventoryReceive: 'Registrar ingresos de mercadería',
    AppPermission.inventoryAdjust: 'Ajustar, trasladar o registrar mermas',
    AppPermission.salesCreate: 'Registrar ventas',
    AppPermission.salesDiscount: 'Aplicar descuentos en ventas',
    AppPermission.reportsViewProfit: 'Ver utilidad y reportes sensibles',
    AppPermission.businessConfigure: 'Configurar el negocio',
  };

  @override
  void initState() {
    super.initState();
    _loadEmployees();
  }

  Future<void> _loadEmployees() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final raw = await ref.read(empleadosRepositoryProvider).obtenerEmpleados();
      final employees = raw
          .whereType<Map>()
          .map((row) => Map<String, dynamic>.from(row))
          .where((row) => row['activo'] == true)
          .toList(growable: false);
      if (!mounted) return;
      setState(() {
        _employees = employees;
        _loading = false;
      });
      if (employees.isNotEmpty) {
        await _selectEmployee((employees.first['id'] as num).toInt());
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = ErrorMapper.map(error);
      });
    }
  }

  Future<void> _selectEmployee(int employeeId) async {
    setState(() {
      _employeeId = employeeId;
      _settings = null;
      _draft = const {};
      _loading = true;
      _error = null;
    });
    try {
      final settings = await ref
          .read(manageEmployeePermissionsUseCaseProvider)
          .load(employeeId);
      if (!mounted || _employeeId != employeeId) return;
      setState(() {
        _settings = settings;
        _draft = {
          for (final row in settings.permissions) row.permission: row.allowed,
        };
        _loading = false;
      });
    } catch (error) {
      if (!mounted || _employeeId != employeeId) return;
      setState(() {
        _loading = false;
        _error = ErrorMapper.map(error);
      });
    }
  }

  Future<void> _save() async {
    final settings = _settings;
    if (settings == null || _saving || settings.isAdministrator) return;
    setState(() => _saving = true);
    try {
      final saved = await ref
          .read(manageEmployeePermissionsUseCaseProvider)
          .save(settings, _draft);
      if (!mounted) return;
      setState(() {
        _settings = saved;
        _draft = {
          for (final row in saved.permissions) row.permission: row.allowed,
        };
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Permisos guardados. Se aplicarán en la próxima revalidación de sesión del empleado.',
          ),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(ErrorMapper.map(error))),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Permisos por empleado')),
      body: RefreshIndicator(
        onRefresh: _loadEmployees,
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            const Text(
              'Los permisos individuales sólo pueden restringir lo que permite el rol. Nunca elevan un Operador a capacidades de Administrador.',
            ),
            const SizedBox(height: 18),
            if (_employees.isNotEmpty)
              DropdownButtonFormField<int>(
                initialValue: _employeeId,
                decoration: const InputDecoration(
                  labelText: 'Empleado activo',
                  border: OutlineInputBorder(),
                ),
                items: _employees
                    .map(
                      (employee) => DropdownMenuItem<int>(
                        value: (employee['id'] as num).toInt(),
                        child: Text(
                          '${employee['nombre'] ?? 'Empleado'} · ${employee['rol'] ?? ''}',
                        ),
                      ),
                    )
                    .toList(growable: false),
                onChanged: _saving
                    ? null
                    : (value) {
                        if (value != null) _selectEmployee(value);
                      },
              ),
            const SizedBox(height: 16),
            if (_loading)
              const Center(
                child: Padding(
                  padding: EdgeInsets.all(28),
                  child: CircularProgressIndicator(),
                ),
              )
            else if (_error != null)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(18),
                  child: Column(
                    children: [
                      Text(_error!, textAlign: TextAlign.center),
                      const SizedBox(height: 12),
                      FilledButton.icon(
                        onPressed: _employeeId == null
                            ? _loadEmployees
                            : () => _selectEmployee(_employeeId!),
                        icon: const Icon(Icons.refresh),
                        label: const Text('Reintentar'),
                      ),
                    ],
                  ),
                ),
              )
            else if (_settings != null) ...[
              if (_settings!.isAdministrator)
                const Card(
                  child: Padding(
                    padding: EdgeInsets.all(16),
                    child: Text(
                      'El Administrador conserva todos los permisos. Para limitar una cuenta, cambia primero su rol a Operador.',
                    ),
                  ),
                ),
              ..._settings!.permissions.map((setting) {
                final allowed = _draft[setting.permission] ?? false;
                return SwitchListTile.adaptive(
                  title: Text(_labels[setting.permission] ?? setting.permission.code),
                  subtitle: Text(
                    setting.baseAllowed
                        ? 'Permitido por el rol base'
                        : 'No disponible para este rol',
                  ),
                  value: allowed,
                  onChanged: _saving ||
                          _settings!.isAdministrator ||
                          !setting.baseAllowed
                      ? null
                      : (value) => setState(() {
                            _draft = {..._draft, setting.permission: value};
                          }),
                );
              }),
              const SizedBox(height: 18),
              FilledButton.icon(
                onPressed:
                    _saving || _settings!.isAdministrator ? null : _save,
                icon: _saving
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.security),
                label: Text(_saving ? 'Guardando...' : 'Guardar permisos'),
              ),
            ] else if (_employees.isEmpty)
              const Center(child: Text('No hay empleados activos.')),
          ],
        ),
      ),
    );
  }
}
