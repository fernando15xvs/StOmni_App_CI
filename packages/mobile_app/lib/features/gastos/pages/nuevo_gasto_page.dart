import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:core_logic/core_logic.dart';
import '../../../home/controllers/home_controller.dart';
import '../../../home/home_notifier.dart';

class NuevoGastoPage extends ConsumerStatefulWidget {
  const NuevoGastoPage({super.key});

  @override
  ConsumerState<NuevoGastoPage> createState() => _NuevoGastoPageState();
}

class _NuevoGastoPageState extends ConsumerState<NuevoGastoPage>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  // Controladores
  final _valorCtrl = TextEditingController();
  final _conceptoCtrl = TextEditingController();

  final DateTime _fecha = AppTime.now();
  bool _esDeuda = false;
  bool _guardando = false;

  List<Map<String, dynamic>> _proveedores = [];
  String? _proveedorId;
  String _categoria = 'Mercadería';

  // Pagos Múltiples (Inicializamos con 1 fila por defecto)
  final List<Map<String, dynamic>> _pagosAnadidos = [
    {
      'montoCtrl': TextEditingController(),
      'metodo': 'Efectivo',
      'afectaCaja': true,
    },
  ];

  final List<String> _categorias = [
    'Mercadería',
    'Servicios',
    'Alquiler',
    'Mantenimiento',
    'Otros',
  ];

  final List<String> _metodos = [
    'Efectivo',
    'Tarjeta',
    'Transferencia',
    'Yape',
    'Plin',
    'Otro',
  ];

  final Color colorRojo = Colors.red;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _tabController.addListener(() {
      if (!mounted) return;
      setState(() {
        _esDeuda = _tabController.index == 1;
      });
    });
    _cargarProveedores();
  }

  @override
  void dispose() {
    _tabController.dispose();
    _valorCtrl.dispose();
    _conceptoCtrl.dispose();
    for (var p in _pagosAnadidos) {
      (p['montoCtrl'] as TextEditingController).dispose();
    }
    super.dispose();
  }

  Future<void> _cargarProveedores() async {
    final data = await ref.read(gastosRepositoryProvider).obtenerProveedores();
    if (mounted) {
      setState(() {
        _proveedores = List<Map<String, dynamic>>.from(data);
        if (_proveedores.isNotEmpty) {
          bool existe = _proveedores.any(
            (p) => p['id'].toString() == _proveedorId,
          );
          if (!existe || _proveedorId == null) {
            _proveedorId = _proveedores.first['id'].toString();
          }
        } else {
          _proveedorId = null;
        }
      });
    }
  }

  void _anadirFilaPago() {
    setState(() {
      _pagosAnadidos.add({
        'montoCtrl': TextEditingController(),
        'metodo': 'Efectivo',
        'afectaCaja': true,
      });
    });
  }

  void _eliminarFilaPago(int index) {
    setState(() {
      final ctrl = _pagosAnadidos[index]['montoCtrl'] as TextEditingController;
      ctrl.dispose();
      _pagosAnadidos.removeAt(index);
    });
  }

  double _calcularTotalPagado() {
    double sum = 0;
    for (var p in _pagosAnadidos) {
      final ctrl = p['montoCtrl'] as TextEditingController;
      sum += double.tryParse(ctrl.text) ?? 0.0;
    }
    return sum;
  }

  Future<void> _guardarGasto() async {
    final montoTotal = double.tryParse(_valorCtrl.text) ?? 0.0;
    if (montoTotal <= 0) {
      _mostrarSnack('Ingresa un Monto Total válido', Colors.red);
      return;
    }

    if (_proveedorId == null) {
      _mostrarSnack('Selecciona un proveedor', Colors.red);
      return;
    }

    final sumaPagos = _calcularTotalPagado();

    if (!_esDeuda && (sumaPagos < montoTotal)) {
      _mostrarSnack(
        'Si está "Pagado", el pago total debe igualar al Monto Total (${AppFormatters.currency(montoTotal)})',
        Colors.red,
      );
      return;
    }

    if (_esDeuda && sumaPagos >= montoTotal) {
      _mostrarSnack(
        'Si es Deuda, los pagos no pueden exceder o igualar el Monto Total',
        Colors.red,
      );
      return;
    }

    // Preparar lista de pagos para la BD (ignorando los que tienen monto 0)
    List<Map<String, dynamic>> pagosParaBD = [];
    double totalAfectaCaja = 0.0;

    for (var p in _pagosAnadidos) {
      final m =
          double.tryParse((p['montoCtrl'] as TextEditingController).text) ??
          0.0;
      if (m > 0) {
        final afectaCaja = p['afectaCaja'] ?? false;
        if (afectaCaja) totalAfectaCaja += m;

        pagosParaBD.add({
          'metodo': p['metodo'],
          'monto': m,
          'afecta_caja_chica': afectaCaja,
        });
      }
    }

    setState(() => _guardando = true);

    try {
      if (totalAfectaCaja > 0) {
        final estadoCaja = await ref
            .read(balanceRepositoryProvider)
            .getEstadoCajaChica();

        if (estadoCaja['estado'] != 'ABIERTA') {
          setState(() => _guardando = false);
          _mostrarSnack(
            'No puedes descontar de la Caja Chica porque está CERRADA.',
            Colors.red,
          );
          return;
        }

        final saldo =
            double.tryParse(estadoCaja['saldo_esperado']?.toString() ?? '0') ??
            0.0;
        if (totalAfectaCaja > saldo) {
          setState(() => _guardando = false);
          _mostrarSnack(
            'El saldo en caja chica (${AppFormatters.currency(saldo)}) es insuficiente.',
            Colors.red,
          );
          return;
        }
      }

      final fechaGuardar = AppTime.toIsoLima(_fecha);

      await ref
          .read(gastosRepositoryProvider)
          .registrarGasto(
            proveedorId: int.parse(_proveedorId!),
            categoria: _categoria,
            montoTotal: montoTotal,
            descripcion: _conceptoCtrl.text,
            fechaIso: fechaGuardar,
            pagos: pagosParaBD,
          );

      if (mounted) {
        _mostrarSnack('Gasto registrado correctamente', Colors.green);
        ref.read(homeTabProvider.notifier).state = 1;
        homeRefreshNotifier.value++;
        Navigator.popUntil(context, (route) => route.isFirst);
      }
    } catch (e) {
      if (!mounted) return;

      String errorStr = e.toString();
      if (errorStr.contains('PostgrestException')) {
        if (errorStr.contains('P0001')) {
          final match = RegExp(r'message:\s*([^,]+)').firstMatch(errorStr);
          errorStr =
              match?.group(1)?.trim() ?? 'Error de validación en el servidor.';
        } else if (errorStr.contains('caja_chica') ||
            errorStr.contains('saldo')) {
          errorStr =
              'El saldo en la caja chica es insuficiente para realizar este pago.';
        } else {
          errorStr =
              'Ocurrió un problema de base de datos al guardar el gasto.';
        }
      } else if (errorStr.contains('SocketException') ||
          errorStr.contains('ClientException') ||
          errorStr.contains('Failed host lookup')) {
        errorStr = 'Revisa tu conexión a internet e inténtalo de nuevo.';
      } else {
        errorStr = errorStr.replaceFirst('Exception: ', '').trim();
      }

      _mostrarSnack(errorStr, Colors.red);
    } finally {
      if (mounted) setState(() => _guardando = false);
    }
  }

  void _mostrarSnack(String msg, Color color) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(msg), backgroundColor: color));
  }

  InputDecoration _decoracionInput(String label, IconData icon) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return InputDecoration(
      labelText: label,
      labelStyle: TextStyle(
        color: isDark ? Colors.white70 : Colors.grey.shade700,
      ),
      floatingLabelStyle: TextStyle(
        color: colorRojo,
        fontWeight: FontWeight.bold,
      ),
      prefixIcon: Icon(icon, color: isDark ? Colors.white70 : Colors.grey),
      filled: true,
      fillColor: isDark ? Colors.grey.shade900 : Colors.white,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(
          color: isDark ? Colors.grey.shade700 : Colors.grey.shade300,
        ),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(
          color: isDark ? Colors.grey.shade700 : Colors.grey.shade300,
        ),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: colorRojo, width: 2),
      ),
      contentPadding: const EdgeInsets.symmetric(vertical: 16, horizontal: 16),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorTema = colorRojo;
    final totalPagado = _calcularTotalPagado();
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        title: const Text(
          'Nuevo Gasto',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        backgroundColor: colorRojo,
        iconTheme: const IconThemeData(color: Colors.white),
        elevation: 0,
      ),
      body: Column(
        children: [
          // TABS RESTAURADAS
          Container(
            color: Theme.of(context).cardColor,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Container(
              height: 50,
              decoration: BoxDecoration(
                color: Theme.of(context).brightness == Brightness.dark
                    ? Colors.black
                    : Colors.grey[100],
                borderRadius: BorderRadius.circular(12),
              ),
              child: TabBar(
                controller: _tabController,
                indicator: BoxDecoration(
                  color: colorTema,
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: [
                    BoxShadow(
                      color: colorTema.withValues(alpha: 0.3),
                      blurRadius: 8,
                      offset: const Offset(0, 3),
                    ),
                  ],
                ),
                labelColor: Colors.white,
                unselectedLabelColor: Colors.grey[600],
                labelStyle: const TextStyle(fontWeight: FontWeight.bold),
                tabs: const [
                  Tab(text: "Pagado"),
                  Tab(text: "Deuda / Crédito"),
                ],
              ),
            ),
          ),

          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: Theme.of(context).cardColor,
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.05),
                      blurRadius: 10,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // FECHA
                    InkWell(
                      onTap:
                          null, // Deshabilitado para evitar manipulación de fecha
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          Text(
                            AppFormatters.limaDateText(_fecha),
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              color:
                                  Theme.of(context).brightness ==
                                      Brightness.dark
                                  ? Colors.white70
                                  : Colors.grey[700],
                            ),
                          ),
                          const SizedBox(width: 8),
                          Icon(
                            Icons.calendar_today,
                            size: 18,
                            color: colorTema,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 15),

                    // MONTO TOTAL
                    TextField(
                      controller: _valorCtrl,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      style: const TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                      ),
                      decoration:
                          _decoracionInput(
                            "Monto Total del Gasto",
                            Icons.attach_money,
                          ).copyWith(
                            prefixText: 'S/ ',
                            prefixStyle: TextStyle(
                              fontSize: 24,
                              fontWeight: FontWeight.bold,
                              color:
                                  Theme.of(context).brightness ==
                                      Brightness.dark
                                  ? Colors.white70
                                  : Colors.grey,
                            ),
                          ),
                      onChanged: (val) => setState(() {}),
                    ),
                    const SizedBox(height: 20),

                    // PROVEEDOR Y CATEGORIA
                    DropdownButtonFormField<String>(
                      isExpanded: true,
                      initialValue: _proveedorId,
                      decoration: _decoracionInput("Proveedor", Icons.store),
                      items: _proveedores
                          .map(
                            (p) => DropdownMenuItem(
                              value: p['id'].toString(),
                              child: Text(
                                p['nombre'],
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          )
                          .toList(),
                      onChanged: (v) => setState(() => _proveedorId = v),
                    ),
                    const SizedBox(height: 15),

                    DropdownButtonFormField<String>(
                      initialValue: _categoria,
                      decoration: _decoracionInput("Categoría", Icons.category),
                      items: _categorias
                          .map(
                            (c) => DropdownMenuItem(value: c, child: Text(c)),
                          )
                          .toList(),
                      onChanged: (v) => setState(() => _categoria = v!),
                    ),

                    const SizedBox(height: 25),

                    // PAGOS MÚLTIPLES
                    Text(
                      _esDeuda ? "Pagos / Abono Inicial" : "Métodos de Pago",
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                      ),
                    ),
                    const SizedBox(height: 10),

                    Container(
                      padding: const EdgeInsets.all(15),
                      decoration: BoxDecoration(
                        color: Theme.of(context).brightness == Brightness.dark
                            ? Colors.red.shade900.withValues(alpha: 0.15)
                            : Colors.red.shade50,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: Theme.of(context).brightness == Brightness.dark
                              ? Colors.red.shade900
                              : Colors.red.shade200,
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          ListView.separated(
                            shrinkWrap: true,
                            physics: const NeverScrollableScrollPhysics(),
                            itemCount: _pagosAnadidos.length,
                            separatorBuilder: (_, _) =>
                                const SizedBox(height: 10),
                            itemBuilder: (context, index) {
                              final p = _pagosAnadidos[index];
                              return Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      // Monto
                                      Expanded(
                                        flex: 3,
                                        child: TextField(
                                          controller:
                                              p['montoCtrl']
                                                  as TextEditingController,
                                          keyboardType:
                                              const TextInputType.numberWithOptions(
                                                decimal: true,
                                              ),
                                          decoration: InputDecoration(
                                            labelText: "Monto",
                                            prefixText: "S/ ",
                                            filled: true,
                                            fillColor:
                                                Theme.of(context).brightness ==
                                                    Brightness.dark
                                                ? Colors.grey.shade900
                                                : Colors.white,
                                            contentPadding:
                                                const EdgeInsets.symmetric(
                                                  horizontal: 10,
                                                  vertical: 12,
                                                ),
                                            border: OutlineInputBorder(
                                              borderRadius:
                                                  BorderRadius.circular(8),
                                              borderSide: BorderSide.none,
                                            ),
                                          ),
                                          onChanged: (v) => setState(() {}),
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      // Metodo
                                      Expanded(
                                        flex: 3,
                                        child: DropdownButtonFormField<String>(
                                          initialValue: p['metodo'],
                                          isExpanded: true,
                                          decoration: InputDecoration(
                                            filled: true,
                                            fillColor:
                                                Theme.of(context).brightness ==
                                                    Brightness.dark
                                                ? Colors.grey.shade900
                                                : Colors.white,
                                            contentPadding:
                                                const EdgeInsets.symmetric(
                                                  horizontal: 10,
                                                  vertical: 12,
                                                ),
                                            border: OutlineInputBorder(
                                              borderRadius:
                                                  BorderRadius.circular(8),
                                              borderSide: BorderSide.none,
                                            ),
                                          ),
                                          items: _metodos
                                              .map(
                                                (m) => DropdownMenuItem(
                                                  value: m,
                                                  child: Text(
                                                    m,
                                                    style: const TextStyle(
                                                      fontSize: 13,
                                                    ),
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                  ),
                                                ),
                                              )
                                              .toList(),
                                          onChanged: (v) =>
                                              setState(() => p['metodo'] = v!),
                                        ),
                                      ),
                                      // Botón Eliminar
                                      if (_pagosAnadidos.length > 1)
                                        IconButton(
                                          padding: EdgeInsets.zero,
                                          constraints: const BoxConstraints(),
                                          icon: const Icon(
                                            Icons.delete,
                                            color: Colors.red,
                                          ),
                                          onPressed: () =>
                                              _eliminarFilaPago(index),
                                        ),
                                    ],
                                  ),
                                  if (p['metodo'] == 'Efectivo') ...[
                                    const SizedBox(height: 5),
                                    Row(
                                      children: [
                                        Checkbox(
                                          value: p['afectaCaja'] ?? false,
                                          onChanged: (val) {
                                            setState(
                                              () => p['afectaCaja'] = val,
                                            );
                                          },
                                          activeColor: colorTema,
                                        ),
                                        Expanded(
                                          child: Text(
                                            "Descontar el dinero de la Caja Chica",
                                            style: TextStyle(
                                              fontSize: 13,
                                              color: isDark
                                                  ? Colors.grey[300]
                                                  : Colors.grey[700],
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ],
                                ],
                              );
                            },
                          ),
                          const SizedBox(height: 10),
                          Center(
                            child: TextButton.icon(
                              onPressed: _anadirFilaPago,
                              icon: const Icon(Icons.add_circle_outline),
                              label: const Text("Añadir Pago"),
                              style: TextButton.styleFrom(
                                foregroundColor: colorRojo,
                              ),
                            ),
                          ),
                          const Divider(),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Text(
                                "PAGO TOTAL:",
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 16,
                                ),
                              ),
                              Text(
                                AppFormatters.currency(totalPagado),
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 18,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 25),

                    TextField(
                      controller: _conceptoCtrl,
                      maxLines: 2,
                      decoration: _decoracionInput(
                        "Descripción / Detalles (Opcional)",
                        Icons.notes,
                      ),
                    ),
                    const SizedBox(height: 10),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
      bottomNavigationBar: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: Theme.of(context).cardColor,
          boxShadow: [
            BoxShadow(
              color: Colors.black12,
              blurRadius: 10,
              offset: const Offset(0, -5),
            ),
          ],
        ),
        child: SafeArea(
          child: SizedBox(
            height: 55,
            child: ElevatedButton(
              onPressed: _guardando ? null : _guardarGasto,
              style: ElevatedButton.styleFrom(
                backgroundColor: colorTema,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(15),
                ),
                elevation: 4,
                shadowColor: colorTema.withValues(alpha: 0.4),
              ),
              child: _guardando
                  ? const CircularProgressIndicator(color: Colors.white)
                  : Text(
                      _esDeuda ? 'REGISTRAR DEUDA' : 'GUARDAR GASTO',
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                        letterSpacing: 1,
                      ),
                    ),
            ),
          ),
        ),
      ),
    );
  }
}
