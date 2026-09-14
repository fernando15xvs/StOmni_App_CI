import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:shimmer/shimmer.dart';
import '../../../core/widgets/global_date_filter.dart';
import 'package:core_logic/core_logic.dart';
import '../../shared/widgets/product_search_widget.dart';
import '../providers/kardex_provider.dart';

class KardexPage extends ConsumerStatefulWidget {
  const KardexPage({super.key});

  @override
  ConsumerState<KardexPage> createState() => _KardexPageState();
}

class _KardexPageState extends ConsumerState<KardexPage> {
  final Color colorPrincipal = const Color(
    0xFF2C3E50,
  ); // Color oscuro para headers

  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(() {
      if (_scrollController.position.pixels >=
          _scrollController.position.maxScrollExtent - 200) {
        ref.read(kardexProvider.notifier).cargarMasKardex();
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (ref.read(rolProvider) != 'admin') return;
      final state = ref.read(kardexProvider);
      if (state.kardexRaw.isEmpty) {
        ref.read(kardexProvider.notifier).cargarKardex();
      } else {
        ref.read(kardexProvider.notifier).cargarKardex(silent: true);
      }
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _seleccionarFechaEspecifica() async {
    final state = ref.read(kardexProvider);
    await GlobalDateFilterWidget.seleccionarFechaEspecifica(
      context: context,
      filterState: state.dateFilter,
      primaryColor: colorPrincipal,
      onSelected: (date) {
        final newFilter = state.dateFilter;
        newFilter.fechaEspecifica = date;
        ref.read(kardexProvider.notifier).updateDateFilter(newFilter);
      },
    );
  }

  Future<void> _seleccionarRango() async {
    final state = ref.read(kardexProvider);
    await GlobalDateFilterWidget.seleccionarRango(
      context: context,
      primaryColor: colorPrincipal,
      onSelected: (range) {
        final newFilter = state.dateFilter;
        newFilter.filtroTipo = 'Personalizado';
        newFilter.rangoPersonalizado = range;
        ref.read(kardexProvider.notifier).updateDateFilter(newFilter);
      },
    );
  }

  Widget _buildHeaderCell(
    String text, {
    double? width,
    double height = 30,
    bool isSubHeader = false,
  }) {
    return Container(
      width: width,
      height: height,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: isSubHeader ? const Color(0xFF34495E) : colorPrincipal,
        border: Border.all(color: Colors.white24, width: 0.5),
      ),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.bold,
          fontSize: 10,
        ),
      ),
    );
  }

  Widget _buildDataCell(
    String text, {
    double? width,
    Color? textColor,
    FontWeight? fontWeight,
    bool isOdd = false,
    Color? bgColor,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      width: width,
      height: 35,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color:
            bgColor ??
            (isOdd
                ? (isDark ? Colors.grey.shade900 : Colors.grey.shade50)
                : Theme.of(context).cardColor),
        border: Border.all(
          color: isDark ? Colors.grey.shade800 : Colors.grey.shade200,
          width: 0.5,
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Text(
          text,
          maxLines: 1,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 11,
            color: textColor ?? (isDark ? Colors.white : Colors.black87),
            fontWeight: fontWeight ?? FontWeight.normal,
          ),
        ),
      ),
    );
  }

  String _formatKardexUnd(Map<String, dynamic> movimiento, dynamic cantRaw) {
    if (cantRaw == null || InventarioMovimientoUtils.toDouble(cantRaw) == 0) {
      return '';
    }
    return InventarioMovimientoUtils.unidadBasePlural(movimiento);
  }

  String _fmtMoney(dynamic value) {
    if (value == null) return '';
    final monto = InventarioMovimientoUtils.toDouble(value);
    if (monto == 0) return '';
    return AppFormatters.currency(monto);
  }

  String _formatKardexQty(
    Map<String, dynamic> movimiento,
    dynamic cantRaw, {
    bool isSaldo = false,
  }) {
    if (cantRaw == null) return isSaldo ? '0' : '';
    final cantidad = InventarioMovimientoUtils.toInt(cantRaw);
    if (cantidad == 0) return isSaldo ? '0' : '';
    return InventarioMovimientoUtils.formatCantidad(
      movimiento,
      cantidad,
      compacta: true,
    );
  }

  Widget _buildShimmerLoading() {
    return Shimmer.fromColors(
      baseColor: Colors.grey.shade300,
      highlightColor: Colors.grey.shade100,
      child: Column(
        children: List.generate(
          10,
          (index) => Container(
            margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
            height: 35,
            color: Theme.of(context).cardColor,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (ref.watch(rolProvider) != 'admin') {
      return const Scaffold(
        body: Center(
          child: Text('Solo el administrador puede consultar el Kardex.'),
        ),
      );
    }

    final state = ref.watch(kardexProvider);

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Kardex de Inventario',
              style: TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w800,
              ),
            ),
            GlobalDateFilterWidget.buildTitleWidget(
              filterState: state.dateFilter,
              onSelectFechaEspecifica: _seleccionarFechaEspecifica,
            ),
          ],
        ),
        backgroundColor: colorPrincipal,
        iconTheme: const IconThemeData(color: Colors.white),
        actions: [
          Theme(
            data: Theme.of(context).copyWith(
              popupMenuTheme: PopupMenuThemeData(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20),
                ),
                color: Theme.of(context).cardColor,
                elevation: 10,
              ),
            ),
            child: PopupMenuButton<String>(
              offset: const Offset(0, 55),
              onSelected: (val) {
                if (val == 'Personalizado') {
                  _seleccionarRango();
                } else {
                  final newFilter = state.dateFilter;
                  newFilter.filtroTipo = val;
                  ref.read(kardexProvider.notifier).updateDateFilter(newFilter);
                }
              },
              icon: Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(
                  Icons.tune_rounded,
                  color: Colors.white,
                  size: 22,
                ),
              ),
              itemBuilder: (context) {
                List<PopupMenuEntry<String>> opciones = [];
                opciones.add(
                  PopupMenuItem(
                    enabled: false,
                    height: 30,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: Theme.of(context).brightness == Brightness.dark
                            ? Colors.grey[800]
                            : Colors.grey[100],
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        "FILTROS DE FECHA",
                        style: TextStyle(
                          color: Theme.of(context).brightness == Brightness.dark
                              ? Colors.grey[300]
                              : Colors.black54,
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                );
                for (String f in [
                  'Diario',
                  'Semanal',
                  'Mensual',
                  'Anual',
                  'Personalizado',
                ]) {
                  opciones.add(
                    PopupMenuItem(
                      value: f,
                      child: Row(
                        children: [
                          Icon(
                            state.dateFilter.filtroTipo == f
                                ? Icons.radio_button_checked
                                : Icons.radio_button_unchecked,
                            color: state.dateFilter.filtroTipo == f
                                ? (Theme.of(context).brightness ==
                                        Brightness.dark
                                    ? Colors.blueAccent
                                    : colorPrincipal)
                                : Colors.grey,
                            size: 18,
                          ),
                          const SizedBox(width: 10),
                          Text(
                            f,
                            style: TextStyle(
                              fontWeight: state.dateFilter.filtroTipo == f
                                  ? FontWeight.bold
                                  : FontWeight.normal,
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                }
                return opciones;
              },
            ),
          ),
          const SizedBox(width: 5),
        ],
      ),
      body: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            color: Theme.of(context).cardColor,
            child: Row(
              children: [
                Expanded(
                  child: ProductSearchWidget(
                    onSearch: (q) => ref
                        .read(almacenRepositoryProvider)
                        .buscarProductosRapido(q, incluirInactivos: true),
                    primaryColor: Colors.blue.shade700,
                    initialValue: state.productoBuscado.isEmpty
                        ? null
                        : state.productoBuscado,
                    onProductoSelected: (p) {
                      final id = (p['id'] as num?)?.toInt();
                      if (id == null) return;
                      ref
                          .read(kardexProvider.notifier)
                          .seleccionarProducto(
                            id,
                            p['nombre']?.toString() ?? '',
                          );
                    },
                    onCleared: () {
                      ref.read(kardexProvider.notifier).limpiarProducto();
                    },
                  ),
                ),
                const SizedBox(width: 10),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: colorPrincipal,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 14,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  onPressed: () => ref
                      .read(kardexProvider.notifier)
                      .cargarKardex(silent: true),
                  child: const Text(
                    "Refrescar",
                    style: TextStyle(color: Colors.white),
                  ),
                ),
              ],
            ),
          ),
          if (state.cargando && state.kardexRaw.isNotEmpty)
            const LinearProgressIndicator(minHeight: 2),
          Expanded(
            child: (state.cargando && state.kardexRaw.isEmpty)
                ? _buildShimmerLoading()
                : state.kardexRaw.isEmpty
                ? const Center(
                    child: Text(
                      "No hay movimientos en este periodo.",
                      style: TextStyle(
                        color: Colors.grey,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  )
                : state.kardexVisible.isEmpty
                ? const Center(
                    child: Text(
                      "No se encontraron productos.",
                      style: TextStyle(
                        color: Colors.red,
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                      ),
                    ),
                  )
                : InteractiveViewer(
                    minScale: 0.4,
                    maxScale: 3.0,
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: SizedBox(
                        width: 2810,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                _buildHeaderCell(
                                  "FECHA",
                                  width: 110,
                                  height: 60,
                                ),
                                _buildHeaderCell(
                                  "PRODUCTO",
                                  width: 200,
                                  height: 60,
                                ),
                                _buildHeaderCell("PCS", width: 40, height: 60),
                                _buildHeaderCell(
                                  "PROVEEDOR",
                                  width: 120,
                                  height: 60,
                                ),
                                Column(
                                  children: [
                                    _buildHeaderCell(
                                      "INGRESO",
                                      width: 425,
                                      height: 30,
                                    ),
                                    Row(
                                      children: [
                                        _buildHeaderCell(
                                          "Cant.",
                                          width: 60,
                                          height: 30,
                                          isSubHeader: true,
                                        ),
                                        _buildHeaderCell(
                                          "Und.",
                                          width: 65,
                                          height: 30,
                                          isSubHeader: true,
                                        ),
                                        _buildHeaderCell(
                                          "Costo",
                                          width: 75,
                                          height: 30,
                                          isSubHeader: true,
                                        ),
                                        _buildHeaderCell(
                                          "P. Principal",
                                          width: 75,
                                          height: 30,
                                          isSubHeader: true,
                                        ),
                                        _buildHeaderCell(
                                          "P. Base Emp.",
                                          width: 75,
                                          height: 30,
                                          isSubHeader: true,
                                        ),
                                        _buildHeaderCell(
                                          "P. Emp. Comp.",
                                          width: 75,
                                          height: 30,
                                          isSubHeader: true,
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                                _buildHeaderCell("TIPO", width: 80, height: 60),
                                Column(
                                  children: [
                                    _buildHeaderCell(
                                      "SALIDA",
                                      width: 395,
                                      height: 30,
                                    ),
                                    Row(
                                      children: [
                                        _buildHeaderCell(
                                          "Cliente",
                                          width: 120,
                                          height: 30,
                                          isSubHeader: true,
                                        ),
                                        _buildHeaderCell(
                                          "Cant.",
                                          width: 60,
                                          height: 30,
                                          isSubHeader: true,
                                        ),
                                        _buildHeaderCell(
                                          "Und.",
                                          width: 65,
                                          height: 30,
                                          isSubHeader: true,
                                        ),
                                        _buildHeaderCell(
                                          "P. Base",
                                          width: 75,
                                          height: 30,
                                          isSubHeader: true,
                                        ),
                                        _buildHeaderCell(
                                          "Total",
                                          width: 75,
                                          height: 30,
                                          isSubHeader: true,
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                                _buildHeaderCell(
                                  "SALDO",
                                  width: 60,
                                  height: 60,
                                ),
                                _buildHeaderCell(
                                  "ALMACÉN",
                                  width: 100,
                                  height: 60,
                                ),
                                _buildHeaderCell(
                                  "OBSERVACIONES",
                                  width: 180,
                                  height: 60,
                                ),
                                _buildHeaderCell(
                                  'VENDIDO POR',
                                  width: 130,
                                  height: 60,
                                ),
                                _buildHeaderCell(
                                  'ANULADO POR',
                                  width: 130,
                                  height: 60,
                                ),
                                _buildHeaderCell(
                                  'MOTIVO ANULACIÓN',
                                  width: 190,
                                  height: 60,
                                ),
                              ],
                            ),
                            Expanded(
                              child: ListView.builder(
                                controller: _scrollController,
                                physics: const AlwaysScrollableScrollPhysics(),
                                itemCount:
                                    state.kardexVisible.length +
                                    (state.hasMore ? 1 : 0),
                                itemBuilder: (context, index) {
                                  if (index == state.kardexVisible.length) {
                                    return Container(
                                      height: 50,
                                      alignment: Alignment.center,
                                      child: const CircularProgressIndicator(),
                                    );
                                  }
                                  final item = state.kardexVisible[index];
                                  final isOdd = index % 2 != 0;
                                  final tipoStr = (item['tipo'] ?? '')
                                      .toString()
                                      .toUpperCase();
                                  final isIngreso =
                                      tipoStr.contains('ENTRADA') ||
                                      tipoStr.contains('INGRESO') ||
                                      tipoStr.contains('ANULACION');
                                  final isSalida =
                                      tipoStr.contains('SALIDA') ||
                                      tipoStr.contains('VENTA') ||
                                      tipoStr.contains('MERMA');

                                  final isDark =
                                      Theme.of(context).brightness ==
                                      Brightness.dark;
                                  Color? colorTipo = isIngreso
                                      ? (isDark
                                            ? Colors.blue.shade300
                                            : Colors.blue.shade700)
                                      : (isSalida
                                            ? (isDark
                                                  ? Colors.orange.shade300
                                                  : Colors.orange.shade700)
                                            : null);
                                  Color? bgIngreso = isIngreso
                                      ? Colors.blue.withValues(alpha: 0.05)
                                      : null;
                                  Color? bgSalida = isSalida
                                      ? Colors.orange.withValues(alpha: 0.05)
                                      : null;

                                  return Row(
                                    children: [
                                      _buildDataCell(
                                        DateFormat('yyyy-MM-dd HH:mm').format(
                                          toLima(item['fecha']),
                                        ),
                                        width: 110,
                                        isOdd: isOdd,
                                      ),
                                      _buildDataCell(
                                        item['producto_nombre'] ?? '',
                                        width: 200,
                                        isOdd: isOdd,
                                        fontWeight: FontWeight.bold,
                                      ),
                                      _buildDataCell(
                                        '${item['pcs'] ?? 1}',
                                        width: 40,
                                        isOdd: isOdd,
                                      ),
                                      _buildDataCell(
                                        item['proveedor'] ?? '',
                                        width: 120,
                                        isOdd: isOdd,
                                      ),
                                      _buildDataCell(
                                        _formatKardexQty(
                                          item,
                                          item['ingreso_cant'],
                                        ),
                                        width: 60,
                                        isOdd: isOdd,
                                        bgColor: bgIngreso,
                                        fontWeight: FontWeight.bold,
                                      ),
                                      _buildDataCell(
                                        _formatKardexUnd(
                                          item,
                                          item['ingreso_cant'],
                                        ),
                                        width: 65,
                                        isOdd: isOdd,
                                        bgColor: bgIngreso,
                                      ),
                                      _buildDataCell(
                                        _fmtMoney(item['ingreso_costo']),
                                        width: 75,
                                        isOdd: isOdd,
                                        bgColor: bgIngreso,
                                      ),
                                      _buildDataCell(
                                        _fmtMoney(item['ingreso_p_unit']),
                                        width: 75,
                                        isOdd: isOdd,
                                        bgColor: bgIngreso,
                                      ),
                                      _buildDataCell(
                                        _fmtMoney(item['ingreso_p_caja']),
                                        width: 75,
                                        isOdd: isOdd,
                                        bgColor: bgIngreso,
                                      ),
                                      _buildDataCell(
                                        _fmtMoney(item['ingreso_p_c_comp']),
                                        width: 75,
                                        isOdd: isOdd,
                                        bgColor: bgIngreso,
                                      ),
                                      _buildDataCell(
                                        item['tipo'] ?? '',
                                        width: 80,
                                        isOdd: isOdd,
                                        textColor: colorTipo,
                                        fontWeight: FontWeight.bold,
                                      ),
                                      _buildDataCell(
                                        item['salida_cliente'] ?? '',
                                        width: 120,
                                        isOdd: isOdd,
                                        bgColor: bgSalida,
                                      ),
                                      _buildDataCell(
                                        _formatKardexQty(
                                          item,
                                          item['salida_cant'],
                                        ),
                                        width: 60,
                                        isOdd: isOdd,
                                        bgColor: bgSalida,
                                        fontWeight: FontWeight.bold,
                                        textColor: isDark
                                            ? Colors.redAccent
                                            : Colors.red.shade700,
                                      ),
                                      _buildDataCell(
                                        _formatKardexUnd(
                                          item,
                                          item['salida_cant'],
                                        ),
                                        width: 65,
                                        isOdd: isOdd,
                                        bgColor: bgSalida,
                                      ),
                                      _buildDataCell(
                                        _fmtMoney(item['salida_p_unit']),
                                        width: 75,
                                        isOdd: isOdd,
                                        bgColor: bgSalida,
                                      ),
                                      _buildDataCell(
                                        _fmtMoney(item['salida_total']),
                                        width: 75,
                                        isOdd: isOdd,
                                        bgColor: bgSalida,
                                        fontWeight: FontWeight.bold,
                                      ),
                                      _buildDataCell(
                                        _formatKardexQty(
                                          item,
                                          item['saldo'],
                                          isSaldo: true,
                                        ),
                                        width: 60,
                                        isOdd: isOdd,
                                        textColor:
                                            (item['saldo'] == null ||
                                                item['saldo'] <= 0)
                                            ? (isDark
                                                  ? Colors.redAccent
                                                  : Colors.red)
                                            : (isDark
                                                  ? Colors.tealAccent
                                                  : Colors.teal.shade700),
                                        fontWeight: FontWeight.w900,
                                      ),
                                      _buildDataCell(
                                        item['almacen_nombre'] ?? '',
                                        width: 100,
                                        isOdd: isOdd,
                                      ),
                                      _buildDataCell(
                                        (item['observaciones'] ?? '')
                                            .toString()
                                            .replaceAll(
                                              RegExp(r' / Vendedor: .*'),
                                              '',
                                            ),
                                        width: 180,
                                        isOdd: isOdd,
                                      ),
                                      _buildDataCell(
                                        item['vendedor_nombre_snapshot'] ?? '',
                                        width: 130,
                                        isOdd: isOdd,
                                      ),
                                      _buildDataCell(
                                        item['anulado_por_nombre_snapshot'] ??
                                            '',
                                        width: 130,
                                        isOdd: isOdd,
                                      ),
                                      _buildDataCell(
                                        item['motivo_anulacion'] ?? '',
                                        width: 190,
                                        isOdd: isOdd,
                                      ),
                                    ],
                                  );
                                },
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}
