import 'package:core_logic/core_logic.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import '../utils/stock_utils.dart';

class EditarPreciosDocumentoPage extends StatefulWidget {
  final SaleCart carritoDetallado;
  final String titulo;
  final Color? colorTema;
  final String textoBoton;
  final void Function(BuildContext context, SaleCart carritoFinal, double total)
  onContinuar;

  const EditarPreciosDocumentoPage({
    super.key,
    required this.carritoDetallado,
    required this.onContinuar,
    this.titulo = 'Definir Precios',
    this.colorTema,
    this.textoBoton = 'CONTINUAR',
  });

  @override
  State<EditarPreciosDocumentoPage> createState() =>
      _EditarPreciosDocumentoPageState();
}

class _EditarPreciosDocumentoPageState
    extends State<EditarPreciosDocumentoPage> {
  final Map<int, _PriceGroup> _grupos = {};
  double _total = 0;

  Color get _tema => widget.colorTema ?? Theme.of(context).colorScheme.primary;

  @override
  void initState() {
    super.initState();
    _crearGrupos();
    _recalcular();
  }

  void _crearGrupos() {
    for (final item in widget.carritoDetallado.lines) {
      final id = item.productId;
      final producto = item.product;
      final grupo = _grupos.putIfAbsent(id, () => _PriceGroup(producto));
      grupo.agregarLinea(item);
    }
  }

  void _recalcular() {
    double suma = 0;
    for (final grupo in _grupos.values) {
      suma += grupo.subtotal;
    }
    if (mounted) setState(() => _total = suma);
  }

  void _continuar() {
    try {
      final salida = <SaleCartLine>[];
      for (final item in widget.carritoDetallado.lines) {
        salida.add(_grupos[item.productId]!.actualizarLinea(item));
      }
      final cart = SaleCart(salida);
      widget.onContinuar(context, cart, cart.totalAmount);
    } catch (error) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(ErrorMapper.map(error))));
    }
  }

  @override
  void dispose() {
    for (final grupo in _grupos.values) {
      grupo.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final grupos = _grupos.values.toList();
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        title: Text(
          widget.titulo,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
          ),
        ),
        backgroundColor: _tema,
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: grupos.length,
        itemBuilder: (context, index) => _tarjeta(grupos[index]),
      ),
      bottomNavigationBar: Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: Theme.of(context).cardColor,
          boxShadow: [BoxShadow(color: Colors.black12, blurRadius: 15)],
        ),
        child: SafeArea(
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Total',
                    style: TextStyle(
                      color: Theme.of(context).brightness == Brightness.dark
                          ? Colors.white
                          : Colors.grey,
                    ),
                  ),
                  Text(
                    'S/ ${NumberFormat('#,##0.00', 'es_PE').format(_total)}',
                    style: TextStyle(
                      fontSize: 25,
                      fontWeight: FontWeight.w900,
                      color: Theme.of(context).brightness == Brightness.dark
                          ? Colors.greenAccent
                          : _tema,
                    ),
                  ),
                ],
              ),
              ElevatedButton.icon(
                onPressed: _total > 0 ? _continuar : null,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF1F2937),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 25,
                    vertical: 15,
                  ),
                ),
                icon: const Icon(Icons.arrow_forward),
                label: Text(widget.textoBoton),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _tarjeta(_PriceGroup grupo) {
    final codigo = grupo.producto.code.trim();
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final accentColor = isDark ? Colors.greenAccent : _tema;
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(16),
        boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 9)],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (codigo.isNotEmpty)
            Text(
              codigo,
              style: TextStyle(
                color: accentColor,
                fontWeight: FontWeight.bold,
                fontSize: 11,
              ),
            ),
          Text(
            grupo.producto.name,
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 5),
          Text(
            grupo.configurado
                ? 'Unidad base: ${grupo.producto.commercialProfile.baseUnit.singularLabel}'
                : '${StockUtils.displayName(grupo.tipoVenta)} · '
                      '${StockUtils.etiquetaContenido(grupo.tipoVenta, grupo.pcs)}',
            style: TextStyle(
              color: isDark ? Colors.white70 : Colors.grey.shade600,
              fontSize: 12,
            ),
          ),
          const Divider(height: 25),
          if (grupo.configurado)
            ...grupo.cantidadesConfiguradas.entries.map(
              (entry) => Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: _panel(
                  titulo: grupo.producto.commercialProfile
                      .find(entry.key)!
                      .format(entry.value.toDouble()),
                  color: Colors.blue,
                  icon: Icons.inventory_2_outlined,
                  children: [
                    _campo(
                      label:
                          'Precio por ${grupo.producto.commercialProfile.find(entry.key)!.singularLabel}',
                      controller: grupo.preciosConfigurados[entry.key]!,
                      destacado: true,
                      onChanged: (_) => _recalcular(),
                    ),
                  ],
                ),
              ),
            )
          else ...[
            if (grupo.tieneCajas) _editorCaja(grupo),
            if (grupo.tieneCajas && grupo.tieneSueltas)
              const SizedBox(height: 12),
            if (grupo.tieneSueltas) _editorSuelto(grupo),
          ],
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: accentColor.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Subtotal del producto',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: accentColor.withValues(alpha: 0.8),
                  ),
                ),
                Text(
                  AppFormatters.currency(grupo.subtotal),
                  style: TextStyle(
                    fontWeight: FontWeight.w900,
                    fontSize: 18,
                    color: accentColor,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _editorCaja(_PriceGroup grupo) {
    final baseLabel = grupo.tipoVenta == SaleUnitType.cajaPaquetes
        ? 'Precio por paquete en caja'
        : grupo.tipoVenta == SaleUnitType.caja
        ? 'Precio por pieza del empaque'
        : 'Precio por unidad en caja';
    return _panel(
      titulo: '${grupo.cantCajas} ${grupo.cantCajas == 1 ? 'Caja' : 'Cajas'}',
      color: Colors.purple,
      icon: Icons.inventory_2_outlined,
      children: [
        Row(
          children: [
            Expanded(
              child: _campo(
                label: baseLabel,
                controller: grupo.precioCajaBaseCtrl,
                onChanged: (value) {
                  final base = double.tryParse(value) ?? 0;
                  grupo.precioCajaFinalCtrl.text = (base * grupo.pcs)
                      .toStringAsFixed(2);
                  _recalcular();
                },
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _campo(
                label: 'Caja completa',
                controller: grupo.precioCajaFinalCtrl,
                destacado: true,
                onChanged: (value) {
                  final total = double.tryParse(value) ?? 0;
                  grupo.precioCajaBaseCtrl.text = (total / grupo.pcs)
                      .toStringAsFixed(2);
                  _recalcular();
                },
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _editorSuelto(_PriceGroup grupo) {
    final paqueteSimple = grupo.tipoVenta == SaleUnitType.paquete;
    final tipoSuelto = StockUtils.tipoUnidadSuelta(grupo.tipoVenta);
    final label = StockUtils.etiquetaUnidadComercial(tipoSuelto, cantidad: 1);

    if (paqueteSimple) {
      return _panel(
        titulo:
            '${grupo.cantSueltas} ${StockUtils.etiquetaUnidadComercial('paquete', cantidad: grupo.cantSueltas)}',
        color: Colors.blue,
        icon: Icons.layers_outlined,
        children: [
          Row(
            children: [
              Expanded(
                child: _campo(
                  label: 'Precio por pieza del paquete',
                  controller: grupo.precioContenidoCtrl,
                  onChanged: (value) {
                    final pieza = double.tryParse(value) ?? 0;
                    grupo.precioSueltoCtrl.text = (pieza * grupo.pcs)
                        .toStringAsFixed(2);
                    _recalcular();
                  },
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _campo(
                  label: 'Paquete completo',
                  controller: grupo.precioSueltoCtrl,
                  destacado: true,
                  onChanged: (value) {
                    final paquete = double.tryParse(value) ?? 0;
                    grupo.precioContenidoCtrl.text = (paquete / grupo.pcs)
                        .toStringAsFixed(2);
                    _recalcular();
                  },
                ),
              ),
            ],
          ),
        ],
      );
    }

    return _panel(
      titulo:
          '${grupo.cantSueltas} '
          '${StockUtils.etiquetaUnidadComercial(tipoSuelto, cantidad: grupo.cantSueltas)}',
      color: Colors.blue,
      icon: Icons.extension_outlined,
      children: [
        _campo(
          label: 'Precio por $label',
          controller: grupo.precioSueltoCtrl,
          destacado: true,
          onChanged: (_) => _recalcular(),
        ),
      ],
    );
  }

  Widget _panel({
    required String titulo,
    required Color color,
    required IconData icon,
    required List<Widget> children,
  }) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.15)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: color, size: 18),
              const SizedBox(width: 8),
              Text(
                titulo,
                style: TextStyle(
                  color: color,
                  fontWeight: FontWeight.w700,
                  fontSize: 15,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          ...children,
        ],
      ),
    );
  }

  Widget _campo({
    required String label,
    required TextEditingController controller,
    required ValueChanged<String> onChanged,
    bool destacado = false,
  }) {
    return TextField(
      controller: controller,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      inputFormatters: [
        FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d*$')),
      ],
      decoration: InputDecoration(
        labelText: label,
        labelStyle: TextStyle(
          color: Theme.of(context).brightness == Brightness.dark
              ? Colors.white
              : Colors.grey.shade600,
          fontSize: 13,
          fontWeight: FontWeight.normal,
        ),
        floatingLabelStyle: TextStyle(
          color: Theme.of(context).brightness == Brightness.dark
              ? Colors.white
              : Colors.grey.shade800,
          fontSize: 13,
          fontWeight: FontWeight.bold,
        ),
        prefixIcon: Padding(
          padding: const EdgeInsets.only(left: 12, right: 4),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                'S/',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: Theme.of(context).brightness == Brightness.dark
                      ? Colors.white
                      : Colors.grey,
                ),
              ),
            ],
          ),
        ),
        prefixIconConstraints: const BoxConstraints(minWidth: 40, minHeight: 0),
        filled: true,
        fillColor: Theme.of(context).brightness == Brightness.dark
            ? Colors.grey.shade900
            : Colors.white,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 14,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(
            color: Theme.of(context).brightness == Brightness.dark
                ? Colors.white24
                : Colors.grey.shade300,
          ),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(
            color: Theme.of(context).brightness == Brightness.dark
                ? Colors.white24
                : Colors.grey.shade300,
          ),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: _tema, width: 1.5),
        ),
      ),
      style: TextStyle(
        fontWeight: FontWeight.bold,
        fontSize: destacado ? 17 : 15,
        color: destacado
            ? (Theme.of(context).brightness == Brightness.dark
                  ? Colors.greenAccent
                  : _tema)
            : (Theme.of(context).brightness == Brightness.dark
                  ? Colors.white
                  : Colors.black87),
      ),
      onChanged: onChanged,
    );
  }
}

class _PriceGroup {
  final SaleProductSnapshot producto;
  late final SaleUnitType tipoVenta;
  late final int pcs;

  int cantCajas = 0;
  int cantSueltas = 0;

  late final TextEditingController precioCajaBaseCtrl;
  late final TextEditingController precioCajaFinalCtrl;
  late final TextEditingController precioSueltoCtrl;
  late final TextEditingController precioContenidoCtrl;
  final Map<String, int> cantidadesConfiguradas = {};
  final Map<String, TextEditingController> preciosConfigurados = {};

  bool get configurado => producto.unitConfiguration != null;

  _PriceGroup(this.producto) {
    tipoVenta = producto.saleType;
    pcs = producto.unitsPerPackage;
    final pUnidad = producto.defaultUnitPrice;
    final pCajaBase = producto.defaultPackageBasePrice;

    final cajaFinal = StockUtils.precioComercialPredeterminado(
      tipoVenta: tipoVenta,
      tipoUnidad: 'caja',
      precioUnidad: pUnidad,
      precioCajaBase: pCajaBase,
      pcs: pcs,
    );
    final suelto = StockUtils.precioComercialPredeterminado(
      tipoVenta: tipoVenta,
      tipoUnidad: StockUtils.tipoUnidadSuelta(tipoVenta),
      precioUnidad: pUnidad,
      precioCajaBase: pCajaBase,
      pcs: pcs,
    );

    precioCajaBaseCtrl = TextEditingController(
      text: (cajaFinal / pcs).toStringAsFixed(2),
    );
    precioCajaFinalCtrl = TextEditingController(
      text: cajaFinal.toStringAsFixed(2),
    );
    precioSueltoCtrl = TextEditingController(text: suelto.toStringAsFixed(2));
    precioContenidoCtrl = TextEditingController(
      text: (tipoVenta == SaleUnitType.paquete ? suelto / pcs : pCajaBase)
          .toStringAsFixed(2),
    );
  }

  void agregarLinea(SaleCartLine item) {
    if (configurado) {
      final code = producto.normalizeUnit(item.commercialUnit);
      cantidadesConfiguradas.update(
        code,
        (value) => value + item.quantity.toInt(),
        ifAbsent: () => item.quantity.toInt(),
      );
      preciosConfigurados.putIfAbsent(
        code,
        () => TextEditingController(
          text:
              (item.commercialUnitPrice > 0
                      ? item.commercialUnitPrice
                      : producto.defaultPrice(code))
                  .toStringAsFixed(2),
        ),
      );
      return;
    }
    final tipo = StockUtils.normalizarTipoUnidad(item.commercialUnit);
    final cantidad = item.quantity.toInt();
    final precioComercial = item.commercialUnitPrice;

    if (tipo == 'caja') {
      cantCajas += cantidad;
      if (precioComercial > 0) {
        precioCajaFinalCtrl.text = precioComercial.toStringAsFixed(2);
        precioCajaBaseCtrl.text = (precioComercial / pcs).toStringAsFixed(2);
      }
    } else {
      cantSueltas += cantidad;
      if (precioComercial > 0) {
        precioSueltoCtrl.text = precioComercial.toStringAsFixed(2);
        if (tipoVenta == SaleUnitType.paquete) {
          precioContenidoCtrl.text = (precioComercial / pcs).toStringAsFixed(2);
        }
      }
    }
  }

  bool get tieneCajas => cantCajas > 0;
  bool get tieneSueltas => cantSueltas > 0;
  double get precioCaja => double.tryParse(precioCajaFinalCtrl.text) ?? 0;
  double get precioSuelto => double.tryParse(precioSueltoCtrl.text) ?? 0;
  double get subtotal => configurado
      ? cantidadesConfiguradas.entries.fold<double>(
          0,
          (sum, entry) =>
              sum +
              entry.value *
                  (double.tryParse(preciosConfigurados[entry.key]!.text) ?? 0),
        )
      : cantCajas * precioCaja + cantSueltas * precioSuelto;

  SaleCartLine actualizarLinea(SaleCartLine original) =>
      const PriceSaleLineUseCase().execute(
        original,
        commercialUnitPrice: configurado
            ? (double.tryParse(
                    preciosConfigurados[producto.normalizeUnit(
                          original.commercialUnit,
                        )]!
                        .text,
                  ) ??
                  0)
            : original.commercialUnit == 'caja'
            ? precioCaja
            : precioSuelto,
      );

  void dispose() {
    precioCajaBaseCtrl.dispose();
    precioCajaFinalCtrl.dispose();
    precioSueltoCtrl.dispose();
    precioContenidoCtrl.dispose();
    for (final controller in preciosConfigurados.values) {
      controller.dispose();
    }
  }
}
