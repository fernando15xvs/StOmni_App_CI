import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import 'historial_pagos_empleado_page.dart';
import 'package:core_logic/core_logic.dart';
import 'nuevo_pago_empleado_page.dart';
import 'package:mobile_app/core/theme/app_colors.dart';
import '../../../core/widgets/app_form_styles.dart';
import '../presentation/controllers/empleados_controller.dart';

class GestionEmpleadosPage extends ConsumerStatefulWidget {
  const GestionEmpleadosPage({super.key});

  @override
  ConsumerState<GestionEmpleadosPage> createState() =>
      _GestionEmpleadosPageState();
}

class _GestionEmpleadosPageState extends ConsumerState<GestionEmpleadosPage> {
  final _nombreCtrl = TextEditingController();
  final _cargoCtrl = TextEditingController();
  final _telefonoCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    // Riverpod initialization is handled by the provider
  }

  // --- FUNCIONES DE CONTACTO ---
  Future<void> _abrirWhatsApp(String telefono) async {
    if (telefono.isEmpty) return;
    String numeroLimpio = telefono.replaceAll(RegExp(r'[^0-9]'), '');
    final url = Uri.parse("https://wa.me/51$numeroLimpio");
    try {
      if (await canLaunchUrl(url)) {
        await launchUrl(url, mode: LaunchMode.externalApplication);
      } else {
        await launchUrl(url);
      }
    } catch (e) {
      /* error */
    }
  }

  Future<void> _llamarEmpleado(String telefono) async {
    if (telefono.isEmpty) return;
    String numeroLimpio = telefono.replaceAll(RegExp(r'[^0-9]'), '');
    final url = Uri.parse("tel:$numeroLimpio");
    if (await canLaunchUrl(url)) await launchUrl(url);
  }

  // --- MODALES (Agregar/Editar) ---
  void _modalGestor({Map<String, dynamic>? empleado}) {
    final esEdicion = empleado != null;
    String rolSeleccionado = 'operador';

    if (esEdicion) {
      _nombreCtrl.text = empleado['nombre'];
      _cargoCtrl.text = empleado['cargo'] ?? '';
      _telefonoCtrl.text = empleado['telefono'] ?? '';
      _emailCtrl.text = empleado['email'] ?? '';
      final rolActual = (empleado['rol'] ?? '').toString().toLowerCase();
      rolSeleccionado = rolActual == 'admin' ? 'admin' : 'operador';
    } else {
      _nombreCtrl.clear();
      _cargoCtrl.clear();
      _telefonoCtrl.clear();
      _emailCtrl.clear();
    }

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setModalState) {
          return AlertDialog(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
            ),
            title: Text(esEdicion ? "Editar Empleado" : "Nuevo Empleado"),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: _nombreCtrl,
                    textCapitalization: TextCapitalization.words,
                    decoration: _inputDecor(
                      context,
                      "Nombre completo",
                      Icons.person,
                    ),
                  ),
                  const SizedBox(height: 15),
                  TextField(
                    controller: _emailCtrl,
                    keyboardType: TextInputType.emailAddress,
                    decoration: _inputDecor(
                      context,
                      "Usuario o Correo (ej. juan o juan@stomni.com)",
                      Icons.email,
                    ),
                    enabled:
                        !esEdicion, // Normalmente el email no se cambia si ya se creó auth
                  ),
                  const SizedBox(height: 15),
                  TextField(
                    controller: _cargoCtrl,
                    textCapitalization: TextCapitalization.words,
                    decoration: _inputDecor(context, "Cargo", Icons.work),
                  ),
                  const SizedBox(height: 15),
                  TextField(
                    controller: _telefonoCtrl,
                    keyboardType: TextInputType.phone,
                    decoration: _inputDecor(context, "Celular", Icons.phone),
                  ),
                  const SizedBox(height: 15),
                  const Text(
                    "Rol en el sistema",
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 5),
                  DropdownButtonFormField<String>(
                    isExpanded: true,
                    dropdownColor: Theme.of(context).cardColor,
                    initialValue: rolSeleccionado,
                    decoration: _inputDecor(context, "Rol", Icons.security),
                    items: const [
                      DropdownMenuItem(
                        value: 'operador',
                        child: Text(
                          'Operador de ventas y almacén',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      DropdownMenuItem(
                        value: 'admin',
                        child: Text('Administrador'),
                      ),
                    ],
                    onChanged: (val) {
                      if (val != null) {
                        setModalState(() => rolSeleccionado = val);
                      }
                    },
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text(
                  "Cancelar",
                  style: TextStyle(color: Colors.grey),
                ),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.personal,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                onPressed: () async {
                  if (_nombreCtrl.text.trim().isEmpty) return;
                  if (!esEdicion && _emailCtrl.text.trim().isEmpty) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text(
                          "El correo es obligatorio para crear el acceso.",
                        ),
                      ),
                    );
                    return;
                  }

                  final data = {
                    'nombre': _nombreCtrl.text.trim(),
                    'cargo': _cargoCtrl.text.trim(),
                    'telefono': _telefonoCtrl.text.trim(),
                    'email': AuthUtils.formatEmail(_emailCtrl.text),
                    'rol': rolSeleccionado,
                    'activo': true,
                  };

                  if (esEdicion) {
                    data['id'] = empleado['id'];
                  }

                  try {
                    final newPassword = await ref
                        .read(empleadosNotifierProvider.notifier)
                        .guardarEmpleado(data, isEdit: esEdicion);
                    if (!ctx.mounted) return;
                    Navigator.pop(ctx);

                    if (newPassword != null) {
                      showDialog(
                        context: context,
                        builder: (c) => AlertDialog(
                          title: const Text("Empleado Creado"),
                          content: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Text(
                                "El empleado fue creado. Entrégale esta contraseña temporal para que inicie sesión:",
                              ),
                              const SizedBox(height: 20),
                              Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  SelectableText(
                                    newPassword,
                                    style: const TextStyle(
                                      fontSize: 22,
                                      fontWeight: FontWeight.bold,
                                      letterSpacing: 2.0,
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  IconButton(
                                    icon: const Icon(
                                      Icons.copy,
                                      color: Colors.blue,
                                    ),
                                    tooltip: "Copiar contraseña",
                                    onPressed: () {
                                      Clipboard.setData(
                                        ClipboardData(text: newPassword),
                                      );
                                      ScaffoldMessenger.of(
                                        context,
                                      ).showSnackBar(
                                        const SnackBar(
                                          content: Text(
                                            "Contraseña copiada correctamente.",
                                          ),
                                          backgroundColor: Colors.green,
                                        ),
                                      );
                                    },
                                  ),
                                ],
                              ),
                            ],
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(c),
                              child: const Text("Entendido"),
                            ),
                          ],
                        ),
                      );
                    }
                  } catch (e) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(ErrorMapper.map(e)),
                        backgroundColor: Colors.red,
                      ),
                    );
                  }
                },
                child: Text(
                  esEdicion ? "Actualizar" : "Guardar",
                  style: const TextStyle(color: Colors.white),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  InputDecoration _inputDecor(
    BuildContext context,
    String label,
    IconData icon,
  ) {
    return AppFormStyles.inputDecor(
      context,
      label,
      icon: icon,
      primaryColor: Theme.of(context).colorScheme.primary,
    );
  }

  Future<void> _eliminarEmpleado(int id) async {
    final confirm = await showDialog(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text("¿Dar de baja?"),
        content: const Text("El empleado pasará a la lista de inactivos."),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text("Cancelar"),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text(
              "Confirmar Baja",
              style: TextStyle(color: Colors.red),
            ),
          ),
        ],
      ),
    );
    if (confirm == true) {
      await ref.read(empleadosNotifierProvider.notifier).darDeBaja(id);
    }
  }

  Future<void> _eliminarEmpleadoDefinitivamente(int id) async {
    final confirm = await showDialog(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text("Eliminar definitivamente"),
        content: const Text(
          "¿Estás seguro de que deseas eliminar definitivamente a este empleado? Esta acción no se puede deshacer.",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text("Cancelar"),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text("Eliminar", style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (confirm == true) {
      if (mounted) {
        showDialog(
          context: context,
          barrierDismissible: false,
          builder: (c) => const Center(child: CircularProgressIndicator()),
        );
      }
      try {
        await ref
            .read(empleadosNotifierProvider.notifier)
            .eliminarDefinitivamente(id);
        if (mounted) {
          Navigator.pop(context);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text("Empleado eliminado definitivamente."),
              backgroundColor: Colors.green,
            ),
          );
        }
      } catch (e) {
        if (mounted) {
          Navigator.pop(context);
          showDialog(
            context: context,
            builder: (c) => AlertDialog(
              title: const Text("No se puede eliminar"),
              content: Text(ErrorMapper.map(e)),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(c),
                  child: const Text("Entendido"),
                ),
              ],
            ),
          );
        }
      }
    }
  }

  Future<void> _reintentarAcceso(Map<String, dynamic> empleado) async {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (c) => const Center(child: CircularProgressIndicator()),
    );
    try {
      final pwd = await ref
          .read(empleadosRepositoryProvider)
          .crearAccesoEmpleado(
            empleado['id'],
            empleado['email'],
            empleado['nombre'],
          );
      if (mounted) {
        Navigator.pop(context);
        if (pwd != null) {
          showDialog(
            context: context,
            builder: (c) => AlertDialog(
              title: const Text("Acceso Creado"),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    "El acceso fue creado correctamente. Entrégale esta contraseña al empleado:",
                  ),
                  const SizedBox(height: 20),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      SelectableText(
                        pwd,
                        style: const TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 2.0,
                        ),
                      ),
                      const SizedBox(width: 10),
                      IconButton(
                        icon: const Icon(Icons.copy, color: Colors.blue),
                        tooltip: "Copiar contraseña",
                        onPressed: () {
                          Clipboard.setData(ClipboardData(text: pwd));
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text(
                                "Contraseña copiada correctamente.",
                              ),
                              backgroundColor: Colors.green,
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () {
                    Navigator.pop(c);
                    ref.invalidate(empleadosNotifierProvider);
                  },
                  child: const Text("Entendido"),
                ),
              ],
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(ErrorMapper.map(e)),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _reactivarEmpleado(int id) async {
    final confirm = await showDialog(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text("¿Reactivar empleado?"),
        content: const Text(
          "El empleado volverá a estar activo en el sistema.",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text("Cancelar"),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text(
              "Reactivar",
              style: TextStyle(color: Colors.green),
            ),
          ),
        ],
      ),
    );
    if (confirm == true) {
      await ref.read(empleadosNotifierProvider.notifier).reactivar(id);
    }
  }

  // --- LÓGICA DE PAGOS Y ADELANTOS ---

  // --- UI PRINCIPAL ---
  @override
  Widget build(BuildContext context) {
    final estadoProvider = ref.watch(empleadosNotifierProvider);
    final empleadosFiltrados = ref.watch(empleadosFiltradosProvider);
    final isActivos = ref.watch(filtroActivosEmpleadosProvider);

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        title: const Text(
          'Gestión de Personal',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        backgroundColor: AppColors.personal,
        iconTheme: const IconThemeData(color: Colors.white),
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.history_edu),
            tooltip: 'Historial Global de Pagos',
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => const HistorialPagosEmpleadoPage(),
                ),
              );
            },
          ),
        ],
      ),
      body: Column(
        children: [
          Container(
            color: AppColors.personal,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Row(
              children: [
                Expanded(
                  child: Container(
                    decoration: BoxDecoration(
                      color: Theme.of(context).cardColor,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: TextField(
                      onChanged: (val) =>
                          ref.read(busquedaEmpleadosProvider.notifier).state =
                              val,
                      decoration: const InputDecoration(
                        hintText: "Buscar por nombre o correo...",
                        prefixIcon: Icon(Icons.search, color: Colors.grey),
                        border: InputBorder.none,
                        contentPadding: EdgeInsets.symmetric(vertical: 14),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Container(
                  decoration: BoxDecoration(
                    color: Theme.of(context).cardColor,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: IconButton(
                    icon: Icon(
                      isActivos ? Icons.check_circle : Icons.cancel,
                      color: isActivos ? Colors.green : Colors.red,
                    ),
                    tooltip: isActivos
                        ? "Mostrando Activos"
                        : "Mostrando Inactivos",
                    onPressed: () {
                      ref.read(filtroActivosEmpleadosProvider.notifier).state =
                          !isActivos;
                    },
                  ),
                ),
              ],
            ),
          ),

          Expanded(
            child: estadoProvider.isLoading && empleadosFiltrados.isEmpty
                ? Center(
                    child: CircularProgressIndicator(color: AppColors.personal),
                  )
                : empleadosFiltrados.isEmpty
                ? Center(
                    child: Text(
                      isActivos
                          ? "No hay empleados activos"
                          : "No hay empleados inactivos",
                      style: TextStyle(color: Colors.grey[600], fontSize: 16),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.only(
                      top: 20,
                      left: 16,
                      right: 16,
                      bottom: 80,
                    ),
                    itemCount: empleadosFiltrados.length,
                    itemBuilder: (ctx, i) {
                      final e = empleadosFiltrados[i];
                      final tieneTel =
                          e['telefono'] != null &&
                          e['telefono'].toString().isNotEmpty;
                      final bool isActivo = e['activo'] == true;

                      return Container(
                        margin: const EdgeInsets.only(bottom: 16),
                        decoration: BoxDecoration(
                          color: Theme.of(context).cardColor,
                          borderRadius: BorderRadius.circular(20),
                          boxShadow: Theme.of(context).brightness == Brightness.dark
                              ? []
                              : [
                                  BoxShadow(
                                    color: Colors.black.withValues(alpha: 0.05),
                                    blurRadius: 10,
                                    offset: const Offset(0, 4),
                                  ),
                                ],
                        ),
                        child: Column(
                          children: [
                            Padding(
                              padding: const EdgeInsets.all(16),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Container(
                                    width: 50,
                                    height: 50,
                                    decoration: BoxDecoration(
                                      color: isActivo
                                          ? AppColors.personal.withValues(
                                              alpha: 0.1,
                                            )
                                          : Colors.grey.withValues(alpha: 0.2),
                                      shape: BoxShape.circle,
                                    ),
                                    child: Center(
                                      child: Text(
                                        e['nombre'][0].toString().toUpperCase(),
                                        style: TextStyle(
                                          fontSize: 22,
                                          fontWeight: FontWeight.w900,
                                          color: isActivo
                                              ? AppColors.personal
                                              : Colors.grey,
                                        ),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 15),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          e['nombre'],
                                          style: TextStyle(
                                            fontSize: 17,
                                            fontWeight: FontWeight.bold,
                                            color: isActivo
                                                ? (Theme.of(context).brightness ==
                                                          Brightness.dark
                                                      ? Colors.white
                                                      : Colors.black87)
                                                : Colors.grey,
                                            decoration: isActivo
                                                ? TextDecoration.none
                                                : TextDecoration.lineThrough,
                                          ),
                                        ),
                                        const SizedBox(height: 4),
                                        Text(
                                          "${e['cargo'] ?? 'Personal'} • ${((e['rol'] ?? '').toString().toLowerCase() == 'admin') ? 'Administrador' : 'Operador de ventas y almacén'}",
                                          style: TextStyle(
                                            color: Colors.grey[600],
                                            fontSize: 13,
                                            fontWeight: FontWeight.w500,
                                          ),
                                        ),
                                        if (e['email'] != null)
                                          Padding(
                                            padding: const EdgeInsets.only(
                                              top: 4,
                                            ),
                                            child: Row(
                                              children: [
                                                Icon(
                                                  Icons.email,
                                                  size: 12,
                                                  color: Colors.grey[400],
                                                ),
                                                const SizedBox(width: 4),
                                                Text(
                                                  e['email'],
                                                  style: TextStyle(
                                                    color: Colors.grey[500],
                                                    fontSize: 12,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        if (tieneTel)
                                          Padding(
                                            padding: const EdgeInsets.only(
                                              top: 4,
                                            ),
                                            child: Row(
                                              children: [
                                                Icon(
                                                  Icons.phone_iphone,
                                                  size: 12,
                                                  color: Colors.grey[400],
                                                ),
                                                const SizedBox(width: 4),
                                                Text(
                                                  e['telefono'],
                                                  style: TextStyle(
                                                    color: Colors.grey[500],
                                                    fontSize: 12,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                      ],
                                    ),
                                  ),
                                  PopupMenuButton<String>(
                                    icon: Icon(
                                      Icons.more_vert,
                                      color: Colors.grey[400],
                                    ),
                                    onSelected: (val) {
                                      if (val == 'edit') {
                                        _modalGestor(empleado: e);
                                      }
                                      if (val == 'delete') {
                                        _eliminarEmpleado(e['id']);
                                      }
                                      if (val == 'reactivate') {
                                        _reactivarEmpleado(e['id']);
                                      }
                                      if (val == 'retry_access') {
                                        _reintentarAcceso(e);
                                      }
                                      if (val == 'hard_delete') {
                                        _eliminarEmpleadoDefinitivamente(
                                          e['id'],
                                        );
                                      }
                                    },
                                    itemBuilder: (context) => [
                                      const PopupMenuItem(
                                        value: 'edit',
                                        child: Row(
                                          children: [
                                            Icon(Icons.edit, size: 20),
                                            SizedBox(width: 10),
                                            Text("Editar"),
                                          ],
                                        ),
                                      ),
                                      if (e['auth_id'] == null &&
                                          e['email'] != null &&
                                          e['email'].toString().isNotEmpty)
                                        const PopupMenuItem(
                                          value: 'retry_access',
                                          child: Row(
                                            children: [
                                              Icon(
                                                Icons.vpn_key,
                                                size: 20,
                                                color: Colors.blue,
                                              ),
                                              SizedBox(width: 10),
                                              Text(
                                                "Crear Acceso",
                                                style: TextStyle(
                                                  color: Colors.blue,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      if (isActivo)
                                        const PopupMenuItem(
                                          value: 'delete',
                                          child: Row(
                                            children: [
                                              Icon(
                                                Icons.person_off,
                                                size: 20,
                                                color: Colors.red,
                                              ),
                                              SizedBox(width: 10),
                                              Text(
                                                "Dar de baja",
                                                style: TextStyle(
                                                  color: Colors.red,
                                                ),
                                              ),
                                            ],
                                          ),
                                        )
                                      else
                                        const PopupMenuItem(
                                          value: 'reactivate',
                                          child: Row(
                                            children: [
                                              Icon(
                                                Icons.person_add,
                                                size: 20,
                                                color: Colors.green,
                                              ),
                                              SizedBox(width: 10),
                                              Text(
                                                "Reactivar",
                                                style: TextStyle(
                                                  color: Colors.green,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      const PopupMenuItem(
                                        value: 'hard_delete',
                                        child: Row(
                                          children: [
                                            Icon(
                                              Icons.delete_forever,
                                              size: 20,
                                              color: Colors.red,
                                            ),
                                            SizedBox(width: 10),
                                            Text(
                                              "Eliminar definitivamente",
                                              style: TextStyle(
                                                color: Colors.red,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),

                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 12,
                              ),
                              decoration: BoxDecoration(
                                color:
                                    Theme.of(context).brightness ==
                                        Brightness.dark
                                    ? Colors.grey[850]
                                    : Colors.grey[50],
                                borderRadius: const BorderRadius.vertical(
                                  bottom: Radius.circular(20),
                                ),
                                border: Border(
                                  top: BorderSide(
                                    color:
                                        Theme.of(context).brightness ==
                                            Brightness.dark
                                        ? Colors.grey[800]!
                                        : Colors.grey.shade100,
                                  ),
                                ),
                              ),
                              child: Row(
                                children: [
                                  if (tieneTel) ...[
                                    _BotonCircular(
                                      icon: Icons.phone,
                                      color: Colors.blue,
                                      onTap: () =>
                                          _llamarEmpleado(e['telefono']),
                                    ),
                                    const SizedBox(width: 10),
                                    _BotonCircular(
                                      icon: Icons.chat,
                                      color: Colors.green,
                                      onTap: () =>
                                          _abrirWhatsApp(e['telefono']),
                                    ),
                                    const SizedBox(width: 10),
                                  ],

                                  const Spacer(),

                                  ElevatedButton(
                                    onPressed: () async {
                                      final res = await Navigator.push(
                                        context,
                                        MaterialPageRoute(
                                          builder: (_) => NuevoPagoEmpleadoPage(
                                            empleado: e,
                                          ),
                                        ),
                                      );
                                      if (res == true) {
                                        // Ya se refresca automáticamente porque el provider escucha DB o se puede hacer ref.invalidate
                                      }
                                    },
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: isActivo
                                          ? AppColors.personal
                                          : Colors.grey,
                                      elevation: 0,
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(12),
                                      ),
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 20,
                                        vertical: 10,
                                      ),
                                    ),
                                    child: const Row(
                                      children: [
                                        Icon(
                                          Icons.attach_money,
                                          size: 18,
                                          color: Colors.white,
                                        ),
                                        SizedBox(width: 5),
                                        Text(
                                          "PAGAR",
                                          style: TextStyle(
                                            fontWeight: FontWeight.bold,
                                            color: Colors.white,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _modalGestor(),
        backgroundColor: AppColors.personal,
        icon: const Icon(Icons.add, color: Colors.white),
        label: const Text(
          "Nuevo Empleado",
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
      ),
    );
  }
}

class _BotonCircular extends StatelessWidget {
  final IconData icon;
  final Color color;
  final VoidCallback onTap;
  const _BotonCircular({
    required this.icon,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(30),
      child: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF2C2C2C) : Colors.white,
          shape: BoxShape.circle,
          border: Border.all(
            color: isDark ? const Color(0xFF3C3C3C) : Colors.grey.shade200,
          ),
          boxShadow: isDark
              ? []
              : [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.05),
                    blurRadius: 4,
                    offset: const Offset(0, 2),
                  ),
                ],
        ),
        child: Icon(icon, color: color, size: 18),
      ),
    );
  }
}
