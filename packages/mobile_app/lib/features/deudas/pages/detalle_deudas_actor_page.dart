import 'package:core_logic/core_logic.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../ventas/pages/ver_venta_page.dart';
import '../../gastos/pages/ver_gasto_page.dart';

class DetalleDeudasActorPage extends ConsumerStatefulWidget {
  final String nombreActor;
  final List<dynamic> items; // Lista de ventas o gastos de este cliente
  final bool esCobro;
  final int actorId;

  const DetalleDeudasActorPage({
    super.key,
    required this.nombreActor,
    required this.items,
    required this.esCobro,
    required this.actorId,
  });

  @override
  ConsumerState<DetalleDeudasActorPage> createState() =>
      _DetalleDeudasActorPageState();
}

class _DetalleDeudasActorPageState
    extends ConsumerState<DetalleDeudasActorPage> {
  late List<dynamic> _listaActual;
  final Color colorVerde = const Color(0xFF0F9D58);
  final Color colorRojo = const Color(0xFFD32F2F);

  @override
  void initState() {
    super.initState();
    _listaActual = widget.items;
  }

  Future<void> _recargarDatos() async {
    if (_listaActual.isEmpty) return;

    try {
      final data = await ref
          .read(deudasRepositoryProvider)
          .obtenerDetalleDeudasActor(widget.actorId, widget.esCobro);
      if (mounted) setState(() => _listaActual = data);
    } catch (e) {
      debugPrint("Error recargando: $e");
    }
  }

  // --- NAVEGACIÓN AL DETALLE (Al tocar la tarjeta) ---
  void _irAlDetalleCompleto(Map<String, dynamic> item) async {
    if (widget.esCobro) {
      await Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => VerVentaPage(ventaId: item['id'])),
      );
    } else {
      await Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => VerGastoPage(gastoId: item['id'])),
      );
    }
    _recargarDatos();
  }

  // --- ELIMINAR OPERACIÓN (Desde los 3 puntos) ---
  Future<void> _eliminarOperacion(Map<String, dynamic> item) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("¿Eliminar Deuda?"),
        content: Text(
          widget.esCobro
              ? "Se eliminará la venta y se devolverá el stock al almacén."
              : "Se eliminará el gasto y su historial.",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text("Cancelar"),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text("Eliminar", style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    try {
      final id = item['id'];
      await ref
          .read(deudasRepositoryProvider)
          .eliminarDeuda(id, widget.esCobro);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Eliminado correctamente")),
        );

        // Eliminamos localmente de la lista para que se vea rapido
        setState(() {
          _listaActual.removeWhere((element) => element['id'] == id);
        });
        // Si quedó vacio, volvemos atrás
        if (_listaActual.isEmpty && mounted) Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(ErrorMapper.map(e)),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  // --- MODAL DE COBRO (ESTILO SUPER LIMPIO) ---
  void _mostrarDialogoPago(Map<String, dynamic> operacion) {
    final saldo = (operacion['saldo'] as num).toDouble();
    final montoCtrl = TextEditingController(text: saldo.toStringAsFixed(2));
    String metodo = 'Efectivo';
    bool descontarDeCaja = false;
    final colorTema = widget.esCobro ? colorVerde : colorRojo;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        decoration: BoxDecoration(
          color: Theme.of(ctx).scaffoldBackgroundColor,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(25)),
        ),
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(ctx).viewInsets.bottom + 20,
          top: 15,
          left: 25,
          right: 25,
        ),
        child: StatefulBuilder(
          builder: (context, setModalState) {
            return SingleChildScrollView(
              child: SafeArea(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Barrita gris superior
                    Center(
                      child: Container(
                        width: 40,
                        height: 4,
                        decoration: BoxDecoration(
                          color: Colors.grey[300],
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                    ),
                    const SizedBox(height: 25),

                    // Título
                    Text(
                      widget.esCobro
                          ? "Cobrar a ${widget.nombreActor}"
                          : "Pagar a ${widget.nombreActor}",
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        color: Theme.of(ctx).brightness == Brightness.dark
                            ? Colors.white
                            : Colors.black87,
                      ),
                    ),
                    const SizedBox(height: 5),

                    // Pendiente Actual
                    Row(
                      children: [
                        const Text(
                          "Pendiente actual: ",
                          style: TextStyle(color: Colors.grey, fontSize: 14),
                        ),
                        Text(
                          AppFormatters.currency(saldo),
                          style: TextStyle(
                            color: colorTema,
                            fontWeight: FontWeight.bold,
                            fontSize: 14,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 30),

                    // INPUT MONTO (Estilo Limpio)
                    const Text(
                      "Monto a procesar",
                      style: TextStyle(
                        fontSize: 13,
                        color: Colors.grey,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Container(
                      decoration: BoxDecoration(
                        color: Theme.of(ctx).brightness == Brightness.dark
                            ? Colors.grey.shade900
                            : Colors.grey[100],
                        borderRadius: BorderRadius.circular(15),
                      ),
                      child: TextField(
                        controller: montoCtrl,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        style: TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.bold,
                          color: Theme.of(ctx).brightness == Brightness.dark
                              ? Colors.white
                              : Colors.black87,
                        ),
                        decoration: const InputDecoration(
                          prefixText: "S/ ",
                          border: InputBorder.none,
                          contentPadding: EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: 15,
                          ),
                        ),
                      ),
                    ),

                    const SizedBox(height: 20),

                    // INPUT MÉTODO (Estilo Limpio)
                    const Text(
                      "Método de Pago",
                      style: TextStyle(
                        fontSize: 13,
                        color: Colors.grey,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      decoration: BoxDecoration(
                        color: Theme.of(ctx).brightness == Brightness.dark
                            ? Colors.grey.shade900
                            : Colors.grey[100],
                        borderRadius: BorderRadius.circular(15),
                      ),
                      child: DropdownButtonHideUnderline(
                        child: DropdownButton<String>(
                          value: metodo,
                          isExpanded: true,
                          icon: const Icon(
                            Icons.keyboard_arrow_down,
                            color: Colors.grey,
                          ),
                          items:
                              [
                                    'Efectivo',
                                    'Yape',
                                    'Plin',
                                    'Tarjeta',
                                    'Transferencia',
                                    'Otro',
                                  ]
                                  .map(
                                    (m) => DropdownMenuItem(
                                      value: m,
                                      child: Text(
                                        m,
                                        style: const TextStyle(
                                          fontSize: 16,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ),
                                  )
                                  .toList(),
                          onChanged: (v) => setModalState(() => metodo = v!),
                        ),
                      ),
                    ),

                    if (!widget.esCobro && metodo == 'Efectivo') ...[
                      const SizedBox(height: 20),
                      Container(
                        decoration: BoxDecoration(
                          color: colorTema.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(15),
                          border: Border.all(
                            color: colorTema.withValues(alpha: 0.3),
                          ),
                        ),
                        child: SwitchListTile(
                          value: descontarDeCaja,
                          activeThumbColor: colorTema,
                          onChanged: (v) =>
                              setModalState(() => descontarDeCaja = v),
                          title: Text(
                            "Descontar de Caja Chica",
                            style: TextStyle(
                              fontWeight: FontWeight.w600,
                              color: Theme.of(ctx).brightness == Brightness.dark
                                  ? Colors.white
                                  : Colors.black87,
                            ),
                          ),
                          subtitle: Text(
                            "Registra este pago como egreso en la caja chica.",
                            style: TextStyle(
                              fontSize: 12,
                              color: Theme.of(ctx).brightness == Brightness.dark
                                  ? Colors.grey[400]
                                  : Colors.grey[700],
                            ),
                          ),
                        ),
                      ),
                    ],

                    const SizedBox(height: 30),

                    // BOTÓN CONFIRMAR
                    SizedBox(
                      width: double.infinity,
                      height: 55,
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: colorTema,
                          elevation: 0,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(15),
                          ),
                        ),
                        onPressed: () async {
                          final abono = double.tryParse(montoCtrl.text) ?? 0.0;
                          if (abono <= 0 || abono > saldo) return;
                          Navigator.pop(ctx);
                          await _procesarPago(
                            operacion['id'],
                            abono,
                            metodo,
                            saldo,
                            descontarDeCaja,
                          );
                        },
                        child: Text(
                          widget.esCobro ? "CONFIRMAR COBRO" : "CONFIRMAR PAGO",
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Future<void> _procesarPago(
    int id,
    double abono,
    String metodo,
    double saldoAnt,
    bool descontarDeCaja,
  ) async {
    try {
      await ref
          .read(deudasRepositoryProvider)
          .registrarPagoDeuda(
            esCliente: widget.esCobro,
            deudaId: id,
            monto: abono,
            metodoPago: metodo,
            fechaIso: AppTime.nowIso(),
            saldoActual: saldoAnt,
            descontarDeCaja: descontarDeCaja,
          );

      if (mounted) {
        // Verificamos si es efectivo y, en caso de pago a proveedor, si el switch está activo
        final anotaEnCaja =
            metodo.toLowerCase() == 'efectivo' &&
            (widget.esCobro || descontarDeCaja);

        final msg = anotaEnCaja
            ? '${widget.esCobro ? 'Cobro' : 'Pago'} registrado y anotado en Caja Chica ✓'
            : '${widget.esCobro ? 'Cobro' : 'Pago'} registrado correctamente ✓';

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(msg), backgroundColor: Colors.green),
        );
        _recargarDatos();
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(ErrorMapper.map(e)),
          backgroundColor: Colors.red,
          duration: const Duration(seconds: 5),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorTema = widget.esCobro ? colorVerde : colorRojo;

    // Calcular Totales Globales
    double deudaTotal = 0;
    double montoOriginalTotal = 0;
    String direccion = "Sin dirección";

    if (_listaActual.isNotEmpty) {
      for (var item in _listaActual) {
        deudaTotal += (item['saldo'] as num).toDouble();
        montoOriginalTotal += (item['monto'] ?? item['total'] as num)
            .toDouble();
      }
      if (widget.esCobro) {
        final c = _listaActual.first['clientes'];
        if (c != null && c['direccion'] != null && c['direccion'] != '-') {
          direccion = c['direccion'];
        }
      }
    }

    final pagadoTotal = montoOriginalTotal - deudaTotal;
    final porcentajeGlobal = montoOriginalTotal == 0
        ? 0.0
        : pagadoTotal / montoOriginalTotal;

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        title: Text(
          widget.nombreActor,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
          ),
        ),
        backgroundColor: colorTema,
        iconTheme: const IconThemeData(color: Colors.white),
        elevation: 0,
      ),
      body: Column(
        children: [
          // 1. DASHBOARD GLOBAL
          Container(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 25),
            decoration: BoxDecoration(
              color: colorTema,
              borderRadius: const BorderRadius.vertical(
                bottom: Radius.circular(30),
              ),
              boxShadow: Theme.of(context).brightness == Brightness.dark
                  ? []
                  : [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.1),
                        blurRadius: 10,
                        offset: const Offset(0, 5),
                      ),
                    ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(
                      Icons.location_on,
                      color: Colors.white70,
                      size: 14,
                    ),
                    const SizedBox(width: 5),
                    Expanded(
                      child: Text(
                        direccion,
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 13,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      "Total Crédito: ${AppFormatters.currency(montoOriginalTotal)}",
                      style: const TextStyle(
                        color: Colors.white70,
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                      ),
                    ),
                    Text(
                      "Debe: ${AppFormatters.currency(deudaTotal)}",
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w900,
                        fontSize: 22,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: porcentajeGlobal,
                    backgroundColor: Colors.black12,
                    color: Colors.white,
                    minHeight: 8,
                  ),
                ),
              ],
            ),
          ),

          // 2. LISTA DE NOTAS
          Expanded(
            child: _listaActual.isEmpty
                ? const Center(child: Text("No hay deudas pendientes"))
                : ListView.builder(
                    padding: const EdgeInsets.all(16),
                    itemCount: _listaActual.length,
                    itemBuilder: (ctx, i) {
                      final item = _listaActual[i];
                      final saldo = (item['saldo'] as num).toDouble();
                      final total = (item['monto'] ?? item['total'] as num)
                          .toDouble();
                      final porcentajeNota = total == 0
                          ? 0.0
                          : (1 - (saldo / total));

                      return Container(
                        margin: const EdgeInsets.only(bottom: 12),
                        decoration: BoxDecoration(
                          color: Theme.of(context).cardColor,
                          borderRadius: BorderRadius.circular(16),
                          boxShadow:
                              Theme.of(context).brightness == Brightness.dark
                              ? []
                              : [
                                  BoxShadow(
                                    color: Colors.black.withValues(alpha: 0.04),
                                    blurRadius: 8,
                                    offset: const Offset(0, 2),
                                  ),
                                ],
                        ),
                        child: Material(
                          color: Colors.transparent,
                          child: InkWell(
                            borderRadius: BorderRadius.circular(16),
                            onTap: () => _irAlDetalleCompleto(
                              item,
                            ), // Click en tarjeta abre detalle completo
                            child: Padding(
                              padding: const EdgeInsets.all(16),
                              child: Column(
                                children: [
                                  Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      // Icono
                                      Container(
                                        padding: const EdgeInsets.all(10),
                                        decoration: BoxDecoration(
                                          color: colorTema.withValues(
                                            alpha: 0.08,
                                          ),
                                          shape: BoxShape.circle,
                                        ),
                                        child: Icon(
                                          Icons.receipt_long,
                                          color: colorTema,
                                          size: 20,
                                        ),
                                      ),
                                      const SizedBox(width: 15),

                                      // Info Nota
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              "${widget.esCobro ? 'Deuda' : 'Gasto'} #${item['id']}",
                                              style: const TextStyle(
                                                fontWeight: FontWeight.bold,
                                                fontSize: 16,
                                              ),
                                            ),
                                            const SizedBox(height: 4),
                                            Text(
                                              AppFormatters.limaDateTimeText(
                                                item['fecha'],
                                              ),
                                              style: TextStyle(
                                                color: Colors.grey[500],
                                                fontSize: 12,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),

                                      // Menú 3 Puntos
                                      PopupMenuButton<String>(
                                        icon: Icon(
                                          Icons.more_vert,
                                          color: Colors.grey[400],
                                        ),
                                        onSelected: (val) {
                                          if (val == 'pagar') {
                                            _mostrarDialogoPago(item);
                                          }
                                          if (val == 'delete') {
                                            _eliminarOperacion(item);
                                          }
                                        },
                                        itemBuilder: (context) => [
                                          PopupMenuItem(
                                            value: 'pagar',
                                            child: Row(
                                              children: [
                                                Icon(
                                                  Icons.payments_outlined,
                                                  color: colorVerde,
                                                  size: 20,
                                                ),
                                                const SizedBox(width: 10),
                                                const Text("Registrar Pago"),
                                              ],
                                            ),
                                          ),
                                          const PopupMenuItem(
                                            value: 'delete',
                                            child: Row(
                                              children: [
                                                Icon(
                                                  Icons.delete_outline,
                                                  color: Colors.red,
                                                  size: 20,
                                                ),
                                                SizedBox(width: 10),
                                                Text("Eliminar Deuda"),
                                              ],
                                            ),
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 15),

                                  // Barra de Progreso y Montos
                                  Row(
                                    mainAxisAlignment:
                                        MainAxisAlignment.spaceBetween,
                                    children: [
                                      Text(
                                        "Total: ${AppFormatters.currency(total)}",
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: Colors.grey[600],
                                        ),
                                      ),
                                      Text(
                                        "Falta: ${AppFormatters.currency(saldo)}",
                                        style: TextStyle(
                                          color: colorTema,
                                          fontWeight: FontWeight.bold,
                                          fontSize: 14,
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 6),
                                  ClipRRect(
                                    borderRadius: BorderRadius.circular(4),
                                    child: LinearProgressIndicator(
                                      value: porcentajeNota,
                                      backgroundColor: Colors.grey[100],
                                      color: colorTema.withValues(alpha: 0.6),
                                      minHeight: 6,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
