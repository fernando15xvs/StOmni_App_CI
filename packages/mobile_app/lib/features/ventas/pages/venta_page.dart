import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';

import 'package:core_logic/core_logic.dart';
import '../../../core/widgets/document_form_kit.dart';
import '../../../home/controllers/home_controller.dart';
import '../presentation/controllers/carrito_controller.dart';

class PagoItem {
  String metodo;
  final TextEditingController montoCtrl;

  PagoItem({required this.metodo, required double montoInicial})
    : montoCtrl = TextEditingController(
        text: montoInicial > 0 ? montoInicial.toStringAsFixed(2) : '',
      );
}

class DetalleVentaPage extends ConsumerStatefulWidget {
  final SaleCart carritoConPreciosFinales;
  final double totalAPagar;
  final int? cotizacionId;
  final Map<String, dynamic>? clientePrellenado;

  const DetalleVentaPage({
    super.key,
    required this.carritoConPreciosFinales,
    required this.totalAPagar,
    this.cotizacionId,
    this.clientePrellenado,
  });

  @override
  ConsumerState<DetalleVentaPage> createState() => _DetalleVentaPageState();
}

class _DetalleVentaPageState extends ConsumerState<DetalleVentaPage>
    with SingleTickerProviderStateMixin {
  final _rucCtrl = TextEditingController();
  final _nombreClienteCtrl = TextEditingController();
  final _direccionCtrl = TextEditingController();
  final _conceptoCtrl = TextEditingController();
  final _abonoCtrl = TextEditingController();

  final DateTime _fecha = AppTime.now();
  bool _guardando = false;
  late TabController _tabController;
  bool _esCredito = false;

  final List<PagoItem> _pagosLista = [];
  final List<String> _metodosDisponibles = [
    'Efectivo',
    'Tarjeta',
    'Yape',
    'Plin',
    'Transferencia',
    'Otro',
  ];
  String _metodoAbono = 'Efectivo';

  String _tipoComprobante = 'ticket_interno';
  final _descuentoGlobalCtrl = TextEditingController();
  final _motivoDescuentoCtrl = TextEditingController();
  bool _aplicarDescuentoPorcentaje = true;
  final String _requestId = const Uuid().v4();

  double get _subtotalBruto => widget.totalAPagar;

  double get _valorDescuentoIngresado =>
      double.tryParse(_descuentoGlobalCtrl.text) ?? 0.0;

  SaleTotals get _totales => SaleCheckout.calculateTotals(
    subtotal: _subtotalBruto,
    discountInput: _valorDescuentoIngresado,
    discountIsPercentage: _aplicarDescuentoPorcentaje,
  );

  double get _descuentoGlobalMonto => _totales.discountAmount;
  double get _descuentoGlobalPorcentaje => _totales.discountPercentage;
  double get _totalFinal => _totales.total;

  Color get colorTema => AppDocColors.venta(context);

  @override
  void initState() {
    super.initState();

    if (widget.clientePrellenado != null) {
      _rucCtrl.text = widget.clientePrellenado!['dni_ruc'] ?? '';
      _nombreClienteCtrl.text = widget.clientePrellenado!['nombre'] ?? '';
      _direccionCtrl.text = widget.clientePrellenado!['direccion'] ?? '';
    }

    _tabController = TabController(length: 2, vsync: this);
    _tabController.addListener(() {
      if (!mounted || _tabController.indexIsChanging) return;

      setState(() {
        _esCredito = _tabController.index == 1;
        if (_esCredito) {
          _tipoComprobante = 'ticket_interno';
        } else {
          _sincronizarPagoUnicoConTotal();
        }
      });
    });

    _pagosLista.add(
      PagoItem(metodo: 'Efectivo', montoInicial: widget.totalAPagar),
    );
  }

  Iterable<SalePaymentInput> get _pagosIngresados => _pagosLista.map(
    (p) => SalePaymentInput(
      method: p.metodo,
      amount: double.tryParse(p.montoCtrl.text) ?? 0.0,
    ),
  );

  double _calcularTotalPagadoLista() =>
      SaleCheckout.totalPaid(_pagosIngresados);

  double get _montoAbono => double.tryParse(_abonoCtrl.text) ?? 0.0;

  void _sincronizarPagoUnicoConTotal() {
    if (_esCredito || _pagosLista.length != 1) return;
    _pagosLista.first.montoCtrl.text = _totalFinal.toStringAsFixed(2);
  }

  List<SalePayment> _construirPagos() {
    return SaleCheckout.buildPayments(
      isCredit: _esCredito,
      cashPayments: _pagosIngresados,
      initialPayment: _montoAbono,
      initialPaymentMethod: _metodoAbono,
    );
  }

  String? _validarAntesDeProcesar() {
    return VentaFormRules.validar(
      fiscalPolicy: ref.read(fiscalPolicyProvider),
      esCredito: _esCredito,
      tipoComprobante: _tipoComprobante,
      fecha: _fecha,
      ahora: AppTime.now(),
      subtotalBruto: _subtotalBruto,
      valorDescuentoIngresado: _valorDescuentoIngresado,
      descuentoEsPorcentaje: _aplicarDescuentoPorcentaje,
      descuentoGlobalMonto: _descuentoGlobalMonto,
      descuentoGlobalPorcentaje: _descuentoGlobalPorcentaje,
      motivoDescuento: _motivoDescuentoCtrl.text,
      totalFinal: _totalFinal,
      totalPagado: _calcularTotalPagadoLista(),
      montoAbono: _montoAbono,
      documentoCliente: _rucCtrl.text,
      nombreCliente: _nombreClienteCtrl.text,
    );
  }

  Future<void> _procesarVenta() async {
    final errorValidacion = _validarAntesDeProcesar();
    if (errorValidacion != null) {
      _mostrarError(errorValidacion);
      return;
    }

    setState(() => _guardando = true);

    try {
      final outcome = await ref
          .read(ventaSubmissionCoordinatorProvider)
          .submit(
            VentaSubmissionRequest(
              requestId: _requestId,
              fecha: _fecha,
              esCredito: _esCredito,
              totalAPagar: _totalFinal,
              montoAbono: _montoAbono,
              concepto: _conceptoCtrl.text.trim(),
              cotizacionId: widget.cotizacionId,
              tipoComprobante: _tipoComprobante,
              subtotalBruto: _subtotalBruto,
              descuentoGlobalPorcentaje: _descuentoGlobalPorcentaje,
              descuentoGlobalMonto: _descuentoGlobalMonto,
              motivoDescuento: _motivoDescuentoCtrl.text.trim(),
              cliente: SaleCustomer(
                ruc: _rucCtrl.text.trim(),
                nombre: _nombreClienteCtrl.text.trim(),
                direccion: _direccionCtrl.text.trim(),
              ),
              pagos: _construirPagos(),
              carrito: widget.carritoConPreciosFinales,
            ),
          );

      if (!mounted) return;

      final colorMensaje = switch (outcome.tone) {
        VentaSubmissionTone.success => Colors.green,
        VentaSubmissionTone.warning => Colors.orange,
        VentaSubmissionTone.error => Colors.red,
      };

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(outcome.message),
          backgroundColor: colorMensaje,
          duration: Duration(seconds: outcome.offlineQueued ? 4 : 5),
        ),
      );

      ref.read(carritoProvider.notifier).limpiarCarrito();
      if (context.mounted) {
        ref.read(homeTabProvider.notifier).state = 1;
        ref.read(homeRefreshRevisionProvider.notifier).state++;
        Navigator.popUntil(context, (route) => route.isFirst);
      }
    } catch (e) {
      String errorMessage = e.toString();
      if (errorMessage.contains('Software caused connection abort') ||
          errorMessage.contains('ClientException') ||
          errorMessage.contains('SocketException') ||
          errorMessage.contains('Failed host lookup')) {
        errorMessage =
            'Se perdió la conexión. Si estabas confirmando, la venta pudo haberse guardado (revisa en "Gestión Tributaria" o el historial antes de reintentar).';
      } else {
        errorMessage = errorMessage
            .replaceFirst('Exception: ', '')
            .replaceFirst('VentaSubmissionException: ', '');
      }
      _mostrarError(errorMessage);
    } finally {
      if (mounted) {
        setState(() => _guardando = false);
      }
    }
  }

  void _mostrarError(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(msg), backgroundColor: Colors.red));
  }

  @override
  void dispose() {
    _rucCtrl.dispose();
    _nombreClienteCtrl.dispose();
    _direccionCtrl.dispose();
    _conceptoCtrl.dispose();
    _abonoCtrl.dispose();
    _descuentoGlobalCtrl.dispose();
    _motivoDescuentoCtrl.dispose();
    _tabController.dispose();
    for (var pago in _pagosLista) {
      pago.montoCtrl.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorTemaActual = _esCredito ? AppDocColors.credito : colorTema;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: isDark
          ? Theme.of(context).scaffoldBackgroundColor
          : Colors.grey[50],
      appBar: AppBar(
        title: const Text(
          'Procesar Venta',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        backgroundColor: colorTema,
        iconTheme: const IconThemeData(color: Colors.white),
        elevation: 0,
      ),
      body: Column(
        children: [
          Container(
            color: isDark ? Theme.of(context).cardColor : Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Container(
              height: 50,
              decoration: BoxDecoration(
                color: isDark
                    ? Theme.of(context).scaffoldBackgroundColor
                    : Colors.grey[100],
                borderRadius: BorderRadius.circular(12),
              ),
              child: TabBar(
                controller: _tabController,
                indicator: BoxDecoration(
                  color: colorTemaActual,
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: [
                    BoxShadow(
                      color: colorTemaActual.withValues(alpha: 0.3),
                      blurRadius: 8,
                      offset: const Offset(0, 3),
                    ),
                  ],
                ),
                labelColor: Colors.white,
                unselectedLabelColor: isDark
                    ? Colors.grey[400]
                    : Colors.grey[600],
                labelStyle: const TextStyle(fontWeight: FontWeight.bold),
                tabs: const [
                  Tab(text: "Cobro Completo"),
                  Tab(text: "Crédito / Deuda"),
                ],
              ),
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  InkWell(
                    onTap: null,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        Text(
                          DateFormat('dd MMM yyyy', 'es').format(_fecha),
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: isDark ? Colors.grey[300] : Colors.grey[700],
                          ),
                        ),
                        const SizedBox(width: 8),
                        Icon(Icons.calendar_today, size: 18, color: colorTema),
                      ],
                    ),
                  ),
                  const SizedBox(height: 15),
                  Center(
                    child: Column(
                      children: [
                        Text(
                          "Total a Pagar",
                          style: TextStyle(
                            color: isDark ? Colors.grey[400] : Colors.grey[600],
                            fontSize: 14,
                          ),
                        ),
                        if (_descuentoGlobalMonto > 0)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 4.0),
                            child: Text(
                              "Subtotal: S/ ${NumberFormat('#,##0.00').format(_subtotalBruto)}\nDescuento: -S/ ${NumberFormat('#,##0.00').format(_descuentoGlobalMonto)}",
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                fontSize: 16,
                                color: Colors.redAccent,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        Text(
                          "S/ ${NumberFormat('#,##0.00').format(_totalFinal)}",
                          style: TextStyle(
                            fontSize: 36,
                            fontWeight: FontWeight.w900,
                            color: isDark ? Colors.white : Colors.black87,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 25),
                  _buildFacturacionYDescuento(),
                  const SizedBox(height: 25),
                  ResumenItemsCard(items: widget.carritoConPreciosFinales),
                  const SizedBox(height: 25),
                  const Text(
                    "Datos del Cliente",
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                  ),
                  const SizedBox(height: 15),
                  ClienteAutocompleteField(
                    nombreCtrl: _nombreClienteCtrl,
                    rucCtrl: _rucCtrl,
                    direccionCtrl: _direccionCtrl,
                    color: colorTema,
                  ),
                  const SizedBox(height: 10),
                  RucDireccionRow(
                    rucCtrl: _rucCtrl,
                    direccionCtrl: _direccionCtrl,
                    nombreCtrl: _nombreClienteCtrl,
                    color: colorTema,
                  ),
                  const SizedBox(height: 30),
                  if (!_esCredito)
                    _buildContenidoPagado()
                  else
                    _buildContenidoDeuda(),
                  const SizedBox(height: 25),
                  TextField(
                    controller: _conceptoCtrl,
                    decoration: appInputDecoration(
                      "Nota o Comentario (Opcional)",
                      Icons.notes,
                      colorTema,
                      isDark: isDark,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
      bottomNavigationBar: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: isDark ? Theme.of(context).cardColor : Colors.white,
          boxShadow: [
            BoxShadow(
              color: isDark ? Colors.black54 : Colors.black12,
              blurRadius: 10,
              offset: const Offset(0, -5),
            ),
          ],
        ),
        child: SafeArea(
          child: SizedBox(
            height: 55,
            child: ElevatedButton(
              onPressed: _guardando ? null : _procesarVenta,
              style: ElevatedButton.styleFrom(
                backgroundColor: colorTemaActual,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(15),
                ),
                elevation: 5,
              ),
              child: _guardando
                  ? const CircularProgressIndicator(color: Colors.white)
                  : Text(
                      _esCredito ? 'REGISTRAR DEUDA' : 'CONFIRMAR VENTA',
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

  Widget _buildContenidoPagado() {
    final pagado = _calcularTotalPagadoLista();
    final restante = _totalFinal - pagado;
    final cuadra = restante.abs() < 0.01;
    final isWide = MediaQuery.of(context).size.width > 500;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: isDark ? Theme.of(context).cardColor : Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isDark ? Colors.grey[700]! : Colors.grey.shade200,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                "Métodos de Pago",
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
              ),
              InkWell(
                onTap: () => setState(
                  () => _pagosLista.add(
                    PagoItem(
                      metodo: 'Efectivo',
                      montoInicial: restante > 0 ? restante : 0,
                    ),
                  ),
                ),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: colorTema.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.add, size: 16, color: colorTema),
                      Text(
                        "Agregar",
                        style: TextStyle(
                          color: colorTema,
                          fontWeight: FontWeight.bold,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 15),
          ..._pagosLista.asMap().entries.map((entry) {
            final i = entry.key;
            final p = entry.value;

            if (!isWide) {
              return Container(
                margin: const EdgeInsets.only(bottom: 15),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  border: Border.all(
                    color: isDark ? Colors.grey[700]! : Colors.grey.shade200,
                  ),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: DropdownButtonFormField<String>(
                            initialValue: p.metodo,
                            isExpanded: true,
                            decoration: InputDecoration(
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 0,
                              ),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(10),
                              ),
                              labelText: "Método",
                            ),
                            items: _metodosDisponibles
                                .map(
                                  (m) => DropdownMenuItem(
                                    value: m,
                                    child: Text(
                                      m,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                )
                                .toList(),
                            onChanged: (v) => setState(() => p.metodo = v!),
                          ),
                        ),
                        if (_pagosLista.length > 1)
                          IconButton(
                            icon: const Icon(
                              Icons.delete_outline,
                              color: Colors.red,
                            ),
                            onPressed: () =>
                                setState(() => _pagosLista.removeAt(i)),
                          ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: p.montoCtrl,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      inputFormatters: [
                        FilteringTextInputFormatter.allow(
                          RegExp(r'^\d*\.?\d*$'),
                        ),
                      ],
                      decoration: InputDecoration(
                        labelText: "Monto",
                        prefixText: 'S/ ',
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 0,
                        ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                      onChanged: (_) => setState(() {}),
                    ),
                  ],
                ),
              );
            }
            return Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(
                children: [
                  Expanded(
                    flex: 4,
                    child: DropdownButtonFormField<String>(
                      initialValue: p.metodo,
                      decoration: InputDecoration(
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 0,
                        ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                      items: _metodosDisponibles
                          .map(
                            (m) => DropdownMenuItem(value: m, child: Text(m)),
                          )
                          .toList(),
                      onChanged: (v) => setState(() => p.metodo = v!),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    flex: 4,
                    child: TextField(
                      controller: p.montoCtrl,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      inputFormatters: [
                        FilteringTextInputFormatter.allow(
                          RegExp(r'^\d*\.?\d*$'),
                        ),
                      ],
                      decoration: InputDecoration(
                        prefixText: 'S/ ',
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 14,
                        ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                  if (_pagosLista.length > 1)
                    IconButton(
                      icon: const Icon(Icons.delete_outline, color: Colors.red),
                      onPressed: () => setState(() => _pagosLista.removeAt(i)),
                    ),
                ],
              ),
            );
          }),
          if (!cuadra)
            Text(
              restante > 0
                  ? "Falta cubrir: S/ ${NumberFormat('#,##0.00').format(restante)}"
                  : "Exceso registrado: S/ ${NumberFormat('#,##0.00').format(restante.abs())}",
              style: const TextStyle(
                color: Colors.red,
                fontWeight: FontWeight.bold,
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildContenidoDeuda() {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: isDark ? Theme.of(context).cardColor : Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isDark ? Colors.grey[700]! : Colors.grey.shade200,
        ),
      ),
      child: Column(
        children: [
          const Text(
            "Estás registrando una venta a crédito.",
            style: TextStyle(color: Colors.grey),
          ),
          const SizedBox(height: 10),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: isDark
                  ? Colors.orange.withValues(alpha: 0.1)
                  : Colors.orange.shade50,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: isDark ? Colors.orange.shade800 : Colors.orange.shade200,
              ),
            ),
            child: const Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.info_outline, color: Colors.orange, size: 20),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Las ventas a crédito generan únicamente Ticket Interno. '
                    'Las facturas y boletas electrónicas se emiten solo al contado.',
                    style: TextStyle(fontSize: 12, height: 1.35),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 15),
          TextField(
            controller: _abonoCtrl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d*$')),
            ],
            decoration: appInputDecoration(
              "Abono Inicial (Opcional)",
              Icons.monetization_on_outlined,
              AppDocColors.credito,
              isDark: isDark,
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 15),
          if (_montoAbono > 0)
            DropdownButtonFormField<String>(
              initialValue: _metodoAbono,
              decoration: appInputDecoration(
                "Método de Abono",
                Icons.payment,
                AppDocColors.credito,
                isDark: isDark,
              ),
              items: _metodosDisponibles
                  .map((m) => DropdownMenuItem(value: m, child: Text(m)))
                  .toList(),
              onChanged: (v) => setState(() => _metodoAbono = v!),
            ),
        ],
      ),
    );
  }

  Widget _buildFacturacionYDescuento() {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: isDark ? Theme.of(context).cardColor : Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isDark ? Colors.grey[700]! : Colors.grey.shade200,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            "Comprobante Electrónico",
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
          ),
          const SizedBox(height: 15),
          DropdownButtonFormField<String>(
            key: ValueKey(_tipoComprobante),
            initialValue: _tipoComprobante,
            decoration: appInputDecoration(
              "Tipo de Comprobante",
              Icons.receipt_long,
              colorTema,
              isDark: isDark,
            ),
            items: _esCredito
                ? const [
                    DropdownMenuItem(
                      value: 'ticket_interno',
                      child: Text('Ticket Interno (No SUNAT)'),
                    ),
                  ]
                : const [
                    DropdownMenuItem(
                      value: 'ticket_interno',
                      child: Text('Ticket Interno (No SUNAT)'),
                    ),
                    DropdownMenuItem(
                      value: 'boleta',
                      child: Text('Boleta Electrónica'),
                    ),
                    DropdownMenuItem(
                      value: 'factura',
                      child: Text('Factura Electrónica'),
                    ),
                  ],
            onChanged: _esCredito
                ? null
                : (v) {
                    if (v == null) return;
                    setState(() => _tipoComprobante = v);
                  },
          ),
          if (_esCredito) ...[
            const SizedBox(height: 8),
            Text(
              'Factura y boleta se habilitan únicamente en la pestaña Contado.',
              style: TextStyle(
                color: Colors.orange.shade800,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
          const SizedBox(height: 25),
          const Text(
            "Descuento Global (Opcional)",
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
          ),
          const SizedBox(height: 15),
          Row(
            children: [
              Expanded(
                flex: 2,
                child: TextField(
                  controller: _descuentoGlobalCtrl,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d*$')),
                  ],
                  decoration: appInputDecoration(
                    _aplicarDescuentoPorcentaje ? "Porcentaje" : "Monto",
                    Icons.discount,
                    colorTema,
                    isDark: isDark,
                  ),
                  onChanged: (_) {
                    setState(_sincronizarPagoUnicoConTotal);
                  },
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                flex: 2,
                child: DropdownButtonFormField<bool>(
                  key: ValueKey(_aplicarDescuentoPorcentaje),
                  initialValue: _aplicarDescuentoPorcentaje,
                  isExpanded: true,
                  decoration: appInputDecoration(
                    "Tipo",
                    Icons.percent,
                    colorTema,
                    isDark: isDark,
                  ),
                  items: const [
                    DropdownMenuItem(
                      value: true,
                      child: Text(
                        '% Porcentaje',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    DropdownMenuItem(
                      value: false,
                      child: Text('S/ Monto', overflow: TextOverflow.ellipsis),
                    ),
                  ],
                  onChanged: (v) {
                    if (v == null) return;
                    setState(() {
                      _aplicarDescuentoPorcentaje = v;
                      _sincronizarPagoUnicoConTotal();
                    });
                  },
                ),
              ),
            ],
          ),
          if (_descuentoGlobalMonto > 0) ...[
            const SizedBox(height: 15),
            TextField(
              controller: _motivoDescuentoCtrl,
              decoration: appInputDecoration(
                "Motivo del descuento",
                Icons.edit_note,
                colorTema,
                isDark: isDark,
              ),
            ),
            if (_descuentoGlobalPorcentaje > 10) ...[
              const SizedBox(height: 10),
              const Text(
                'Este descuento requiere autorización. '
                'Por ahora se autoriza automáticamente solo cuando '
                'la sesión pertenece a un administrador.',
                style: TextStyle(
                  color: Colors.orange,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ],
        ],
      ),
    );
  }
}
