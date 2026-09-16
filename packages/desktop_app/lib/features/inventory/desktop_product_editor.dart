import 'package:core_logic/core_logic.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'desktop_product_admin.dart';

class DesktopProductEditor extends ConsumerStatefulWidget {
  const DesktopProductEditor({super.key, this.product});

  final Producto? product;

  @override
  ConsumerState<DesktopProductEditor> createState() =>
      _DesktopProductEditorState();
}

class _DesktopProductEditorState extends ConsumerState<DesktopProductEditor> {
  late final TextEditingController _code;
  late final TextEditingController _name;
  late final TextEditingController _unitPrice;
  late final TextEditingController _packagePrice;
  late final TextEditingController _purchasePrice;
  late final TextEditingController _unitsPerPackage;
  late final TextEditingController _minimumStock;
  late SaleUnitType _saleType;
  int? _supplierId;
  bool _allowWithoutStock = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final product = widget.product;
    _code = TextEditingController(text: product?.codigo ?? '');
    _name = TextEditingController(text: product?.nombre ?? '');
    _unitPrice = TextEditingController(
      text: product == null ? '' : product.precioUnidad.toString(),
    );
    _packagePrice = TextEditingController(
      text: product?.precioCaja?.toString() ?? '0',
    );
    _purchasePrice = TextEditingController(
      text: product == null ? '' : product.precioCompra.toString(),
    );
    _unitsPerPackage = TextEditingController(
      text: (product?.cantidadPorCaja ?? 1).toString(),
    );
    _minimumStock = TextEditingController(
      text: product == null ? '0' : product.stockMinimo.toString(),
    );
    _saleType = product?.legacySaleType ?? SaleUnitType.unidad;
    _supplierId = product?.proveedorId;
    _allowWithoutStock = product?.permitirSinStock ?? false;
  }

  @override
  void dispose() {
    _code.dispose();
    _name.dispose();
    _unitPrice.dispose();
    _packagePrice.dispose();
    _purchasePrice.dispose();
    _unitsPerPackage.dispose();
    _minimumStock.dispose();
    super.dispose();
  }

  double _number(TextEditingController controller, {double fallback = 0}) =>
      double.tryParse(controller.text.trim().replaceAll(',', '.')) ?? fallback;

  Future<void> _save(ProductFormCatalog catalog) async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final useCase = ref.read(desktopSaveProductUseCaseProvider);
      final result = await useCase.execute(
        SaveProductCommand(
          requestId: useCase.createRequestId(),
          productId: widget.product?.id,
          code: _code.text,
          name: _name.text,
          unitPrice: _number(_unitPrice),
          packageBasePrice: _number(_packagePrice),
          purchasePrice: _number(_purchasePrice),
          unitsPerPackage: int.tryParse(_unitsPerPackage.text.trim()) ?? 1,
          saleUnitType: _saleType,
          minimumStock: _number(_minimumStock),
          supplierId: _supplierId,
          allowWithoutStock: _allowWithoutStock,
          newImageBytes: null,
          existingImageUrl: widget.product?.imagenPath,
          warehouseIds: catalog.warehouses
              .map((row) => row.id)
              .toList(growable: false),
          boxesByWarehouse: const {},
          baseUnitsByWarehouse: const {},
        ),
      );
      if (!mounted) return;
      Navigator.of(context).pop(result);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.toString())));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String _saleTypeLabel(SaleUnitType value) => switch (value) {
    SaleUnitType.unidad => 'Unidad',
    SaleUnitType.caja => 'Caja',
    SaleUnitType.paquete => 'Paquete',
    SaleUnitType.cajaUnidades => 'Caja + unidades',
    SaleUnitType.cajaPaquetes => 'Caja + paquetes',
    SaleUnitType.ambos => 'Caja + unidades (ambos)',
  };

  @override
  Widget build(BuildContext context) {
    final catalog = ref.watch(desktopProductFormCatalogProvider);
    return AlertDialog(
      title: Text(
        widget.product == null ? 'Nuevo producto' : 'Editar producto',
      ),
      content: SizedBox(
        width: 620,
        child: catalog.when(
          loading: () => const SizedBox(
            height: 220,
            child: Center(child: CircularProgressIndicator()),
          ),
          error: (error, _) => SizedBox(
            height: 220,
            child: Center(child: Text(error.toString())),
          ),
          data: (data) => SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _code,
                        decoration: const InputDecoration(labelText: 'Código'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      flex: 2,
                      child: TextField(
                        controller: _name,
                        decoration: const InputDecoration(labelText: 'Nombre'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: DropdownButtonFormField<SaleUnitType>(
                        initialValue: _saleType,
                        decoration: const InputDecoration(
                          labelText: 'Tipo de venta legacy',
                        ),
                        items: SaleUnitType.values
                            .map(
                              (value) => DropdownMenuItem(
                                value: value,
                                child: Text(_saleTypeLabel(value)),
                              ),
                            )
                            .toList(growable: false),
                        onChanged: _saving
                            ? null
                            : (value) => setState(
                                () => _saleType = value ?? _saleType,
                              ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        controller: _unitsPerPackage,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: false,
                        ),
                        decoration: const InputDecoration(
                          labelText: 'Unidades por empaque',
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _unitPrice,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        decoration: const InputDecoration(
                          labelText: 'Precio base',
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        controller: _packagePrice,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        decoration: const InputDecoration(
                          labelText: 'Precio base empaque',
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        controller: _purchasePrice,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        decoration: const InputDecoration(labelText: 'Costo'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _minimumStock,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        decoration: const InputDecoration(
                          labelText: 'Stock mínimo',
                          helperText:
                              'Admite decimales para perfiles escalados.',
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: DropdownButtonFormField<int?>(
                        initialValue:
                            data.suppliers.any((row) => row.id == _supplierId)
                            ? _supplierId
                            : null,
                        decoration: const InputDecoration(
                          labelText: 'Proveedor',
                        ),
                        items: [
                          const DropdownMenuItem<int?>(
                            value: null,
                            child: Text('Sin proveedor'),
                          ),
                          ...data.suppliers.map(
                            (row) => DropdownMenuItem<int?>(
                              value: row.id,
                              child: Text(row.name),
                            ),
                          ),
                        ],
                        onChanged: _saving
                            ? null
                            : (value) => setState(() => _supplierId = value),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Permitir venta sin stock'),
                  subtitle: const Text(
                    'El stock inicial se registra después mediante Ingreso de Mercadería para conservar el contrato decimal.',
                  ),
                  value: _allowWithoutStock,
                  onChanged: _saving
                      ? null
                      : (value) => setState(() => _allowWithoutStock = value),
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancelar'),
        ),
        catalog.maybeWhen(
          data: (data) => FilledButton.icon(
            onPressed: _saving ? null : () => _save(data),
            icon: _saving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.save_outlined),
            label: const Text('Guardar'),
          ),
          orElse: () => const SizedBox.shrink(),
        ),
      ],
    );
  }
}
