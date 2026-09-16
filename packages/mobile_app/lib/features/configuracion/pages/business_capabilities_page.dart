import 'package:core_logic/core_logic.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'employee_permissions_page.dart';

class BusinessCapabilitiesPage extends ConsumerStatefulWidget {
  const BusinessCapabilitiesPage({super.key});

  @override
  ConsumerState<BusinessCapabilitiesPage> createState() =>
      _BusinessCapabilitiesPageState();
}

class _BusinessCapabilitiesPageState
    extends ConsumerState<BusinessCapabilitiesPage> {
  BusinessProfile? _profile;
  BusinessCapabilities? _draft;
  String? _error;
  bool _loading = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (_loading || _saving) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final profile = await ref.read(businessProfileGatewayProvider).load();
      if (!mounted) return;
      setState(() {
        _profile = profile;
        _draft = profile.capabilities;
      });
    } catch (error) {
      if (mounted) setState(() => _error = ErrorMapper.map(error));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _save() async {
    if (_saving || _profile == null || _draft == null) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final saved = await ref
          .read(updateBusinessCapabilitiesUseCaseProvider)
          .execute(_profile!, _draft!);
      if (!mounted) return;
      setState(() {
        _profile = saved;
        _draft = saved.capabilities;
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Capacidades guardadas.')));
    } catch (error) {
      if (mounted) setState(() => _error = ErrorMapper.map(error));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final profile = _profile;
    final draft = _draft;
    final isAdmin = ref
        .watch(appPermissionsProvider)
        .contains(AppPermission.businessConfigure);
    final canSave =
        !_saving &&
        !_loading &&
        profile != null &&
        profile.supportsCapabilitySettings &&
        isAdmin;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Capacidades del negocio'),
        actions: [
          IconButton(
            onPressed: _saving || _loading ? null : _load,
            tooltip: 'Recargar configuración',
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(20),
              children: [
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: Text(_error!),
                  ),
                if (profile != null && draft != null) ...[
                  Text(
                    profile.displayName,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Estos ajustes controlan nuevas operaciones. No eliminan ventas, deudas ni documentos existentes.',
                  ),
                  if (!profile.supportsCapabilitySettings)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 16),
                      child: Text(
                        'El servidor conserva la configuración anterior. Se requiere instalar la migración de capacidades para editar estos ajustes.',
                      ),
                    ),
                  SwitchListTile(
                    title: const Text('Ventas a crédito'),
                    value: draft.creditSales,
                    onChanged: canSave
                        ? (value) => setState(
                            () => _draft = draft.withSales(creditSales: value),
                          )
                        : null,
                  ),
                  SwitchListTile(
                    title: const Text('Emisión electrónica'),
                    value: draft.electronicInvoicing,
                    onChanged: canSave
                        ? (value) => setState(
                            () => _draft = draft.withSales(
                              electronicInvoicing: value,
                            ),
                          )
                        : null,
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'Lotes, vencimientos, variantes, servicios y series aún no se pueden activar. Requieren completar su almacenamiento y sus flujos.',
                  ),
                  const SizedBox(height: 24),
                  FilledButton(
                    onPressed: canSave ? _save : null,
                    child: Text(_saving ? 'Guardando…' : 'Guardar capacidades'),
                  ),
                  if (isAdmin) ...[
                    const SizedBox(height: 28),
                    const Divider(),
                    const SizedBox(height: 12),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.admin_panel_settings_outlined),
                      title: const Text('Permisos por empleado'),
                      subtitle: const Text(
                        'Restringe permisos del rol Operador sin conceder privilegios administrativos.',
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const EmployeePermissionsPage(),
                        ),
                      ),
                    ),
                  ],
                ],
              ],
            ),
    );
  }
}
