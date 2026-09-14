import 'package:core_logic/core_logic.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class ProductQuantityDialog extends StatefulWidget {
  const ProductQuantityDialog({
    super.key,
    required this.producto,
    required this.configAlmacenes,
    required this.carritoActual,
    required this.onConfirm,
    required this.colorTema,
    this.aplicarRestriccionStock = true,
  });

  final Map<String, dynamic> producto;
  final List<Map<String, dynamic>> configAlmacenes;
  final SaleCart carritoActual;
  final void Function(List<SaleCartLine> newItems) onConfirm;
  final Color colorTema;
  final bool aplicarRestriccionStock;

  @override
  State<ProductQuantityDialog> createState() => _ProductQuantityDialogState();
}

class _ProductQuantityDialogState extends State<ProductQuantityDialog> {
  final Map<(int, String), TextEditingController> _controllers = {};
  late final SaleProductSnapshot _product;
  late final ProductUnitProfile _profile;

  @override
  void initState() {
    super.initState();
    _product = SaleCartMapper.decodeProduct(widget.producto);
    _profile = _product.commercialProfile;
    for (final warehouse in widget.configAlmacenes) {
      final warehouseId = (warehouse['id'] as num).toInt();
      for (final presentation in _profile.presentations) {
        var quantity = 0.0;
        for (final line in widget.carritoActual.lines) {
          if (line.productId == (widget.producto['id'] as num).toInt() &&
              line.warehouseId == warehouseId &&
              _product.normalizeUnit(line.commercialUnit) == presentation.code) {
            quantity += line.quantity;
          }
        }
        _controllers[(warehouseId, presentation.code)] = TextEditingController(
          text: quantity > 0 ? CommercialPresentation.formatNumber(quantity) : '',
        );
      }
    }
  }

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  int _stock(int warehouseId) {
    final rows = widget.producto['inventario_almacen'];
    if (rows is! List) return 0;
    for (final row in rows) {
      if (row is Map && (row['almacen_id'] as num?)?.toInt() == warehouseId) {
        return (row['cantidad'] as num?)?.toInt() ?? 0;
      }
    }
    return 0;
  }

  SaleCartLine _line({required int warehouseId, required String warehouseName,
      required CommercialPresentation presentation, required int quantity}) {
    return const PriceSaleLineUseCase().execute(
      SaleCartLine(
        productId: (widget.producto['id'] as num).toInt(),
        product: _product,
        warehouseId: warehouseId,
        warehouseName: warehouseName,
        quantity: quantity.toDouble(),
        commercialUnit: presentation.code,
        subtotal: 0,
      ),
      commercialUnitPrice: _product.defaultPrice(presentation.code),
    );
  }

  void _confirm() {
    try {
      final result = <SaleCartLine>[];
      var adjusted = false;
      for (final warehouse in widget.configAlmacenes) {
        final warehouseId = (warehouse['id'] as num).toInt();
        final warehouseName = warehouse['nombre']?.toString() ?? 'Almacén';
        final quantities = <String, int>{};
        for (final presentation in _profile.presentations) {
          final raw = _controllers[(warehouseId, presentation.code)]!.text.trim();
          final quantity = raw.isEmpty ? 0 : int.tryParse(raw);
          if (quantity == null ||
              quantity < 0 ||
              quantity > IntegerPresentationPolicy.maxQuantity) {
            throw const FormatException(
              'Las cantidades deben ser enteros no negativos dentro del rango permitido.',
            );
          }
          quantities[presentation.code] = quantity;
        }

        final ordered = [..._profile.presentations]
          ..sort((a, b) => b.baseQuantity.compareTo(a.baseQuantity));
        final currentStock = _stock(warehouseId);
        var remaining = currentStock < 0 ? 0 : currentStock;
        final restrict = widget.aplicarRestriccionStock &&
            widget.producto['permitir_sin_stock'] != true;
        for (final presentation in ordered) {
          var quantity = quantities[presentation.code] ?? 0;
          if (quantity == 0) continue;
          final factor = presentation.baseQuantity.toInt();
          if (restrict && quantity > remaining ~/ factor) {
            quantity = remaining ~/ factor;
            adjusted = true;
          }
          if (quantity <= 0) continue;
          if (restrict) remaining -= quantity * factor;
          result.add(_line(warehouseId: warehouseId,
              warehouseName: warehouseName,
              presentation: presentation, quantity: quantity));
        }
      }
      final messenger = ScaffoldMessenger.maybeOf(context);
      widget.onConfirm(result);
      Navigator.pop(context);
      if (adjusted) {
        messenger?.showSnackBar(
          const SnackBar(
            content: Text('Stock insuficiente. Se ajustó al máximo disponible.'),
            backgroundColor: Colors.orange,
          ),
        );
      }
    } catch (error) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(ErrorMapper.map(error))),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final code = widget.producto['codigo']?.toString().trim() ?? '';
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
      title: Column(children: [
        if (code.isNotEmpty)
          Text(code, style: TextStyle(fontSize: 11, color: widget.colorTema,
              fontWeight: FontWeight.bold)),
        Text(widget.producto['nombre']?.toString() ?? 'Producto',
            textAlign: TextAlign.center,
            style: const TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 4),
        Text('Cantidad por presentación · base: ${_profile.baseUnit.singularLabel}',
            style: const TextStyle(fontSize: 12, color: Colors.grey)),
        if (widget.producto['permitir_sin_stock'] == true)
          Container(
            margin: const EdgeInsets.only(top: 6),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: Colors.orange.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(5),
            ),
            child: const Text(
              'Venta sin stock permitida',
              style: TextStyle(
                fontSize: 10,
                color: Colors.orange,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
      ]),
      content: SizedBox(
        width: MediaQuery.of(context).size.width * 0.85,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: widget.configAlmacenes.map((warehouse) {
              final id = (warehouse['id'] as num).toInt();
              final stock = _stock(id);
              return Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(warehouse['nombre']?.toString() ?? 'Almacén',
                      style: const TextStyle(fontWeight: FontWeight.bold)),
                  Text('Stock: ${_profile.formatBaseQuantity(stock.toDouble())}',
                      style: TextStyle(fontSize: 11,
                          color: stock > 0 ? Colors.green[700] : Colors.red,
                          fontWeight: FontWeight.w600)),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: _profile.presentations.map((presentation) =>
                      SizedBox(width: 135, child: TextField(
                        controller: _controllers[(id, presentation.code)],
                        keyboardType: TextInputType.number,
                        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                        textAlign: TextAlign.center,
                        decoration: InputDecoration(
                          labelText: presentation.pluralLabel,
                          helperText: presentation.baseQuantity == 1
                              ? 'Unidad base'
                              : '= ${presentation.baseQuantity.toInt()} ${_profile.baseUnit.pluralLabel}',
                          isDense: true,
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                        ),
                      )),
                    ).toList(),
                  ),
                ]),
              );
            }).toList(),
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
        ElevatedButton(onPressed: _confirm,
            style: ElevatedButton.styleFrom(backgroundColor: widget.colorTema),
            child: const Text('Confirmar', style: TextStyle(color: Colors.white))),
      ],
    );
  }
}
