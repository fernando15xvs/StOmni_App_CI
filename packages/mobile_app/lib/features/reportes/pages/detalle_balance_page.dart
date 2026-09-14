import 'package:mobile_app/platform/documents/mobile_document_output.dart';
import 'package:core_logic/core_logic.dart';
import 'package:flutter/material.dart';
import 'package:mobile_app/core/theme/app_colors.dart';

class DetalleBalancePage extends StatefulWidget {
  final DateTime fechaInicio;
  final DateTime fechaFin;
  final List<Map<String, dynamic>> movimientos;
  final double totalDescuentos;

  const DetalleBalancePage({
    super.key,
    required this.fechaInicio,
    required this.fechaFin,
    required this.movimientos,
    required this.totalDescuentos,
  });

  @override
  State<DetalleBalancePage> createState() => _DetalleBalancePageState();
}

class _DetalleBalancePageState extends State<DetalleBalancePage> {
  bool _cargando = true;

  Map<String, Map<String, double>> _desglosePorMetodo = {};
  double _totalIngresos = 0;
  double _totalEgresos = 0;
  double _totalDescuentos = 0;

  final Color colorPrincipal = AppColors.reportes;
  final Color colorSecundario = Colors.red;

  final List<String> _listaMetodos = [
    'Efectivo',
    'Efectivo (Externo)',
    'Tarjeta',
    'Yape',
    'Plin',
    'Transferencia',
    'Otro',
  ];

  @override
  void initState() {
    super.initState();
    _calcularDesglose();
  }

  @override
  void didUpdateWidget(covariant DetalleBalancePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.movimientos != oldWidget.movimientos) {
      _calcularDesglose();
    }
  }

  Future<void> _calcularDesglose() async {
    if (mounted) {
      setState(() => _cargando = true);
    }

    final desglose = <String, Map<String, double>>{
      for (final metodo in _listaMetodos)
        metodo: {
          'ingreso': 0.0,
          'egreso': 0.0,
        },
    };

    double ingresos = 0;
    double egresos = 0;

    for (final mov in widget.movimientos) {
      final monto =
          (mov['monto'] as num?)?.toDouble() ??
          0.0;

      final esIngreso =
          (mov['tipo'] ?? '')
              .toString()
              .toLowerCase() ==
          'ingreso';

      if (esIngreso) {
        ingresos += monto;
      } else {
        egresos += monto;
      }

      final metodo = _normalizarMetodo(
        mov['metodo']?.toString() ?? 'Otro',
      );

      final clave = esIngreso ? 'ingreso' : 'egreso';

      desglose.putIfAbsent(
        metodo,
        () => {
          'ingreso': 0.0,
          'egreso': 0.0,
        },
      );

      desglose[metodo]![clave] =
          desglose[metodo]![clave]! + monto;
    }

    if (!mounted) return;

    setState(() {
      _totalIngresos = ingresos;
      _totalEgresos = egresos;
      _totalDescuentos = widget.totalDescuentos;
      _desglosePorMetodo = desglose;
      _cargando = false;
    });
  }

  String _normalizarMetodo(String input) {
    for (var m in _listaMetodos) {
      if (m.toLowerCase() == input.toLowerCase()) return m;
    }
    return 'Otro';
  }

  Future<void> _descargarPDF() async {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) =>
          const Center(child: CircularProgressIndicator(color: Colors.white)),
    );

    try {
      final document = await DetallePdfService.generar(
        fechaInicio: widget.fechaInicio,
        fechaFin: widget.fechaFin,
        totalIngresos: _totalIngresos,
        totalEgresos: _totalEgresos,
        totalDescuentos: _totalDescuentos,
        desglose: _desglosePorMetodo,
      );
      if (!mounted) return;
      final resultado = await documentOutputFor(context).deliver(document);

      if (!mounted) return;
      Navigator.pop(context);

      if (resultado == DocumentOutputResult.saved) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text("PDF guardado correctamente en tu PC."),
            backgroundColor: colorPrincipal,
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(ErrorMapper.map(e)),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    double balanceNeto = _totalIngresos - _totalEgresos;

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        title: const Text(
          'Detalle del balance',
          style: TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
            fontSize: 18,
          ),
        ),
        backgroundColor: colorPrincipal,
        iconTheme: const IconThemeData(color: Colors.white),
        elevation: 0,
        actions: [
          Tooltip(
            message: "Descargar / Compartir PDF",
            child: InkWell(
              onTap: _cargando ? null : _descargarPDF,
              borderRadius: BorderRadius.circular(12),
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.3),
                  ),
                ),
                child: const Icon(
                  Icons.picture_as_pdf_rounded,
                  color: Colors.white,
                  size: 20,
                ),
              ),
            ),
          ),
        ],
      ),
      body: _cargando
          ? Center(child: CircularProgressIndicator(color: colorPrincipal))
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // --- TARJETA RESUMEN SUPERIOR ---
                  Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: Theme.of(context).cardColor,
                      borderRadius: BorderRadius.circular(16),
                      border: Theme.of(context).brightness == Brightness.dark
                          ? null
                          : Border.all(color: Colors.grey.shade200),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.01),
                          blurRadius: 10,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: Column(
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Column(
                                children: [
                                  Text(
                                    "Ingresos",
                                    style: TextStyle(
                                      color: colorPrincipal,
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    AppFormatters.currency(_totalIngresos),
                                    style: TextStyle(
                                      fontWeight: FontWeight.w800,
                                      fontSize: 20,
                                      color:
                                          Theme.of(context).brightness ==
                                              Brightness.dark
                                          ? Colors.white
                                          : Colors.black87,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Container(
                              width: 1,
                              height: 40,
                              color: Colors.grey.shade300,
                            ),
                            Expanded(
                              child: Column(
                                children: [
                                  Text(
                                    "Egresos",
                                    style: TextStyle(
                                      color: Colors.red[600],
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    AppFormatters.currency(_totalEgresos),
                                    style: TextStyle(
                                      fontWeight: FontWeight.w800,
                                      fontSize: 20,
                                      color:
                                          Theme.of(context).brightness ==
                                              Brightness.dark
                                          ? Colors.white
                                          : Colors.black87,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            if (_totalDescuentos > 0) ...[
                              Container(
                                width: 1,
                                height: 40,
                                color: Colors.grey.shade300,
                              ),
                              Expanded(
                                child: Column(
                                  children: [
                                    Text(
                                      "Descuentos en ventas",
                                      style: TextStyle(
                                        color: Colors.orange,
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      AppFormatters.currency(_totalDescuentos),
                                      style: TextStyle(
                                        fontWeight: FontWeight.w800,
                                        fontSize: 20,
                                        color:
                                            Theme.of(context).brightness ==
                                                Brightness.dark
                                            ? Colors.white
                                            : Colors.black87,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ],
                        ),
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 16),
                          child: Divider(height: 1, color: Colors.black12),
                        ),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text(
                              "Balance Neto",
                              style: TextStyle(
                                color: Colors.grey,
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            Text(
                              AppFormatters.currency(balanceNeto),
                              style: TextStyle(
                                color: balanceNeto >= 0
                                    ? colorPrincipal
                                    : colorSecundario,
                                fontWeight: FontWeight.w900,
                                fontSize: 20,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),

                  // --- MOSTRAR MENSAJE SI NO HAY MOVIMIENTOS ---
                  if (_totalIngresos == 0 && _totalEgresos == 0)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 40),
                      child: Center(
                        child: Text(
                          "No hay movimientos en este periodo.",
                          style: TextStyle(
                            color: Colors.grey,
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    )
                  else ...[
                    // --- SUBTÍTULOS ---
                    Text(
                      "Resumen por Método de Pago",
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                        color: Theme.of(context).brightness == Brightness.dark
                            ? Colors.white
                            : Colors.black87,
                      ),
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      "Desglose de ingresos y egresos según medio:",
                      style: TextStyle(color: Colors.grey, fontSize: 12),
                    ),
                    const SizedBox(height: 16),

                    // --- LISTA DE MÉTODOS PLEGABLES ---
                    ..._desglosePorMetodo.entries.map((entry) {
                      final metodo = entry.key;
                      final valores = entry.value;
                      final ingreso = valores['ingreso']!;
                      final egreso = valores['egreso']!;
                      final neto = ingreso - egreso;

                      if (ingreso == 0 && egreso == 0) {
                        return const SizedBox.shrink();
                      }

                      return _buildMetodoDesplegableCard(
                        metodo,
                        ingreso,
                        egreso,
                        neto,
                      );
                    }),
                  ],
                ],
              ),
            ),
    );
  }

  Widget _buildMetodoDesplegableCard(
    String metodo,
    double ingreso,
    double egreso,
    double neto,
  ) {
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(16),
        border: Theme.of(context).brightness == Brightness.dark
            ? null
            : Border.all(color: Colors.grey.shade200),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.02),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          iconColor: colorPrincipal,
          collapsedIconColor: Colors.grey[500],
          tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          title: Row(
            children: [
              _buildIconoMetodo(context, metodo),
              const SizedBox(width: 12),
              Text(
                metodo,
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                  color: Theme.of(context).brightness == Brightness.dark
                      ? Colors.white
                      : const Color(0xFF2D3748),
                ),
              ),
            ],
          ),
          trailing: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                AppFormatters.currency(neto),
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 16,
                  letterSpacing: -0.5,
                  color: neto >= 0
                      ? (Theme.of(context).brightness == Brightness.dark
                            ? Colors.white
                            : Colors.black87)
                      : colorSecundario,
                ),
              ),
              const Text(
                "Neto",
                style: TextStyle(
                  color: Colors.grey,
                  fontSize: 10,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Theme.of(context).brightness == Brightness.dark
                    ? Colors.grey[900]
                    : Colors.grey[50],
                borderRadius: const BorderRadius.vertical(
                  bottom: Radius.circular(16),
                ),
              ),
              child: Column(
                children: [
                  _filaDetalleInterno(
                    "Ingresos",
                    ingreso,
                    colorPrincipal,
                    Icons.arrow_circle_up_outlined,
                  ),
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 8),
                    child: Divider(height: 1, color: Colors.black12),
                  ),
                  _filaDetalleInterno(
                    "Egresos",
                    egreso,
                    Colors.red[600]!,
                    Icons.arrow_circle_down_outlined,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildIconoMetodo(BuildContext context, String metodo) {
    Color color;
    IconData icon;

    switch (metodo) {
      case 'Efectivo':
        color = Colors.green;
        icon = Icons.payments_rounded;
        break;
      case 'Efectivo (Externo)':
        color = Colors.teal;
        icon = Icons.monetization_on_rounded;
        break;
      case 'Tarjeta':
        color = Colors.blue;
        icon = Icons.credit_card_rounded;
        break;
      case 'Yape':
        color = Colors.purple;
        icon = Icons.qr_code_2_rounded;
        break;
      case 'Plin':
        color = Colors.cyan;
        icon = Icons.qr_code_rounded;
        break;
      case 'Transferencia':
        color = Colors.indigo;
        icon = Icons.account_balance_rounded;
        break;
      default:
        color = Colors.grey;
        icon = Icons.receipt_long_rounded;
    }

    final isDark = Theme.of(context).brightness == Brightness.dark;

    Color iconColor = color;
    if (isDark && color is MaterialColor) {
      iconColor = color.shade300;
    }

    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: isDark
            ? color.withValues(alpha: 0.15)
            : (color is MaterialColor
                  ? color.shade50
                  : color.withValues(alpha: 0.1)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Icon(icon, color: iconColor),
    );
  }

  Widget _filaDetalleInterno(
    String label,
    double valor,
    Color color,
    IconData icon,
  ) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Row(
          children: [
            Icon(icon, color: color, size: 18),
            const SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: Theme.of(context).brightness == Brightness.dark
                    ? Colors.white70
                    : Colors.black54,
              ),
            ),
          ],
        ),
        Text(
          "${color == colorPrincipal ? '+' : '-'} ${AppFormatters.currency(valor)}",
          style: TextStyle(
            color: color,
            fontWeight: FontWeight.w800,
            fontSize: 14,
          ),
        ),
      ],
    );
  }
}
