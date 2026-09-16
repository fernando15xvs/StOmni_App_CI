import 'package:core_logic/core_logic.dart';
import 'package:core_logic/features/ventas/providers/sale_pricing_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../inventory/desktop_inventory_controller.dart';

class DesktopSalesPanel extends ConsumerStatefulWidget {
  const DesktopSalesPanel({super.key});

  @override
  ConsumerState<DesktopSalesPanel> createState() => _DesktopSalesPanelState();
}

class _DesktopSalesPanelState extends ConsumerState<DesktopSalesPanel> {
  final _searchController = TextEditingController();
  final _customerNameController = TextEditingController(
    text: 'CLIENTE GENERAL',
  );
  final _customerDocumentController = TextEditingController();
  final _customerAddressController = TextEditingController();
  final _discountController = TextEditingController();
  final _discountReasonController = TextEditingController();
  final _downPaymentController = TextEditingController();

  SaleCart _cart = SaleCart.empty();
  String _query = '';
  String _paymentMethod = 'yape';
  String _documentType = 'ticket_interno';
  bool _credit = false;
  bool _processing = false;

  @override
  void dispose() {
    _searchController.dispose();
    _customerNameController.dispose();
    _customerDocumentController.dispose();
    _customerAddressController.dispose();
    _discountController.dispose();
    _discountReasonController.dispose();
    _downPaymentController.dispose();
    super.dispose();
  }

  SaleProductSnapshot _snapshotFor(Producto product) {
    return SaleProductSnapshot(
      code: product.codigo ?? '',
      name: product.nombre,
      saleType: product.legacySaleType,
      unitsPerPackage: product.cantidadPorCaja ?? 1,
      defaultUnitPrice: product.precioUnidad,
      defaultPackageBasePrice: (product.precioCaja ?? 0) > 0
          ? product.precioCaja!
          : product.precioUnidad,
      weightKg: product.pesoKg,
      dispatchUnit: product.unidadGre,
      unitConfiguration: product.unitConfiguration,
    );
  }

  TextInputFormatter _quantityFormatter(int precision) {
    return TextInputFormatter.withFunction((oldValue, newValue) {
      final text = newValue.text.replaceAll(',', '.');
      final regex = RegExp('^\\d*(?:\\.\\d{0,$precision})?\$');
      if (!regex.hasMatch(text)) return oldValue;
      return newValue.copyWith(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      );
    });
  }

  double _stockFor(Producto product, int warehouseId) {
    for (final row in product.inventario) {
      if (row.almacenId == warehouseId) return row.cantidad;
    }
    return 0;
  }

  Future<void> _addProduct(
    InventoryCatalogItem item,
    List<InventoryWarehouseRecord> warehouses,
  ) async {
    final activeWarehouses = warehouses
        .where((warehouse) => warehouse.active)
        .toList();
    if (activeWarehouses.isEmpty) {
      _showMessage('No hay almacenes activos disponibles.', error: true);
      return;
    }

    final product = item.product;
    final productSnapshot = _snapshotFor(product);
    final profile = item.commercialProfile;
    var presentationCode = profile.baseUnit.code;
    var quantityText = '1';

    int selectedWarehouse = activeWarehouses.first.id;
    for (final stock in product.inventario) {
      if (stock.cantidad > 0 &&
          activeWarehouses.any(
            (warehouse) => warehouse.id == stock.almacenId,
          )) {
        selectedWarehouse = stock.almacenId;
        break;
      }
    }

    final line = await showDialog<SaleCartLine>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            final presentation = profile.find(presentationCode)!;
            final price = productSnapshot.defaultPrice(presentation.code);
            final stock = _stockFor(product, selectedWarehouse);
            return AlertDialog(
              title: Text(product.nombre),
              content: SizedBox(
                width: 480,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    DropdownButtonFormField<int>(
                      initialValue: selectedWarehouse,
                      decoration: const InputDecoration(labelText: 'Almacén'),
                      items: activeWarehouses
                          .map(
                            (warehouse) => DropdownMenuItem(
                              value: warehouse.id,
                              child: Text(warehouse.name),
                            ),
                          )
                          .toList(growable: false),
                      onChanged: (value) {
                        if (value != null) {
                          setDialogState(() => selectedWarehouse = value);
                        }
                      },
                    ),
                    const SizedBox(height: 14),
                    DropdownButtonFormField<String>(
                      initialValue: presentationCode,
                      decoration: const InputDecoration(
                        labelText: 'Presentación',
                      ),
                      items: profile.presentations
                          .map(
                            (presentation) => DropdownMenuItem(
                              value: presentation.code,
                              child: Text(
                                '${presentation.singularLabel} · '
                                '${CommercialPresentation.formatNumber(presentation.baseQuantity)} base',
                              ),
                            ),
                          )
                          .toList(growable: false),
                      onChanged: (value) {
                        if (value != null) {
                          setDialogState(() {
                            presentationCode = value;
                            quantityText = '1';
                          });
                        }
                      },
                    ),
                    const SizedBox(height: 14),
                    TextFormField(
                      key: ValueKey(presentationCode),
                      initialValue: quantityText,
                      keyboardType: TextInputType.numberWithOptions(
                        decimal: presentation.quantityPrecision > 0,
                      ),
                      inputFormatters: [
                        _quantityFormatter(presentation.quantityPrecision),
                      ],
                      decoration: InputDecoration(
                        labelText: 'Cantidad (${presentation.pluralLabel})',
                      ),
                      onChanged: (value) => quantityText = value,
                    ),
                    const SizedBox(height: 14),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        'Precio catálogo: S/ ${price.toStringAsFixed(2)} por ${presentation.singularLabel}',
                      ),
                    ),
                    const SizedBox(height: 6),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        'La promoción vigente se resolverá al agregar la línea.',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        'Stock base en almacén: ${CommercialPresentation.formatNumber(stock)} ${profile.baseUnit.pluralLabel}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                    if (product.unitConfiguration != null) ...[
                      const SizedBox(height: 6),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          presentation.fiscalUnitCode == null
                              ? 'Sin código fiscal: esta presentación sólo puede usarse con Ticket Interno.'
                              : 'Unidad fiscal: ${presentation.fiscalUnitCode}',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: const Text('Cancelar'),
                ),
                FilledButton(
                  onPressed: () async {
                    final quantity = double.tryParse(
                      quantityText.trim().replaceAll(',', '.'),
                    );
                    if (quantity == null ||
                        !quantity.isFinite ||
                        quantity <= 0) {
                      return;
                    }
                    try {
                      FixedQuantity.fromDouble(
                        quantity,
                        scale: presentation.quantityPrecision,
                      );
                      final priced = await ref
                          .read(authoritativePriceSaleLineUseCaseProvider)
                          .execute(
                            SaleCartLine(
                              productId: product.id,
                              warehouseId: selectedWarehouse,
                              warehouseName: activeWarehouses
                                  .firstWhere(
                                    (warehouse) =>
                                        warehouse.id == selectedWarehouse,
                                  )
                                  .name,
                              product: productSnapshot,
                              quantity: quantity,
                              commercialUnit: presentationCode,
                              subtotal: 0,
                            ),
                          );
                      final baseQuantity = priced.recordedBaseQuantity ?? 0;
                      if (!product.permitirSinStock &&
                          baseQuantity - stock > 0.000001) {
                        if (dialogContext.mounted) {
                          ScaffoldMessenger.of(dialogContext).showSnackBar(
                            const SnackBar(
                              content: Text('Stock insuficiente.'),
                            ),
                          );
                        }
                        return;
                      }
                      if (dialogContext.mounted) {
                        Navigator.of(dialogContext).pop(priced);
                      }
                    } catch (error) {
                      if (dialogContext.mounted) {
                        ScaffoldMessenger.of(dialogContext).showSnackBar(
                          SnackBar(content: Text(ErrorMapper.map(error))),
                        );
                      }
                    }
                  },
                  child: const Text('Agregar'),
                ),
              ],
            );
          },
        );
      },
    );

    if (line == null || !mounted) return;
    setState(() {
      _cart = _cart.replaceProductLines(product.id, [line]);
    });
  }

  double get _grossTotal => _cart.totalAmount;

  double get _discount {
    final value =
        double.tryParse(_discountController.text.trim().replaceAll(',', '.')) ??
        0;
    if (!value.isFinite || value <= 0) return 0;
    return value > _grossTotal ? _grossTotal : value;
  }

  double get _netTotal => _grossTotal - _discount;

  double get _downPayment {
    if (!_credit) return _netTotal;
    final value =
        double.tryParse(
          _downPaymentController.text.trim().replaceAll(',', '.'),
        ) ??
        0;
    if (!value.isFinite || value <= 0) return 0;
    return value > _netTotal ? _netTotal : value;
  }

  Future<void> _submitSale() async {
    if (_cart.isEmpty || _processing) return;
    final gross = _grossTotal;
    final discount = _discount;
    final total = _netTotal;
    final payment = _downPayment;
    if (!gross.isFinite || gross <= 0 || !total.isFinite || total <= 0) {
      _showMessage('El total de la venta no es válido.', error: true);
      return;
    }
    if (discount > 0 && _discountReasonController.text.trim().isEmpty) {
      _showMessage('Indica el motivo del descuento.', error: true);
      return;
    }
    if (_credit && payment >= total - 0.000001) {
      _showMessage(
        'Una venta al crédito debe conservar un saldo pendiente; usa contado si se pagará completa.',
        error: true,
      );
      return;
    }

    setState(() => _processing = true);
    try {
      final payments = payment <= 0
          ? const <SalePayment>[]
          : [SalePayment(metodo: _paymentMethod, monto: payment)];
      final request = VentaSubmissionRequest(
        requestId: const Uuid().v4(),
        fecha: AppTime.now(),
        esCredito: _credit,
        totalAPagar: total,
        montoAbono: payment,
        concepto: 'Venta desde StOmni Desktop',
        tipoComprobante: _documentType,
        subtotalBruto: gross,
        descuentoGlobalPorcentaje: gross <= 0 ? 0 : (discount / gross) * 100,
        descuentoGlobalMonto: discount,
        motivoDescuento: _discountReasonController.text.trim(),
        cliente: SaleCustomer(
          ruc: _customerDocumentController.text.trim(),
          nombre: _customerNameController.text.trim().isEmpty
              ? 'CLIENTE GENERAL'
              : _customerNameController.text.trim(),
          direccion: _customerAddressController.text.trim(),
        ),
        pagos: payments,
        carrito: _cart,
      );

      final outcome = await ref
          .read(ventaSubmissionCoordinatorProvider)
          .submit(request);
      if (!mounted) return;
      _showMessage(
        outcome.message,
        error: outcome.tone == VentaSubmissionTone.error,
      );
      if (outcome.tone != VentaSubmissionTone.error) {
        setState(() {
          _cart = SaleCart.empty();
          _discountController.clear();
          _discountReasonController.clear();
          _downPaymentController.clear();
        });
        ref.invalidate(desktopInventorySnapshotProvider);
      }
    } catch (error) {
      if (mounted) _showMessage(ErrorMapper.map(error), error: true);
    } finally {
      if (mounted) setState(() => _processing = false);
    }
  }

  void _showMessage(String message, {bool error = false}) {
    if (!mounted) return;
    final colors = Theme.of(context).colorScheme;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: error ? colors.error : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = ref.watch(desktopInventorySnapshotProvider);

    return snapshot.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => Center(
        child: FilledButton.icon(
          onPressed: () => ref.invalidate(desktopInventorySnapshotProvider),
          icon: const Icon(Icons.refresh),
          label: Text('Reintentar: $error'),
        ),
      ),
      data: (catalog) {
        final products = ref
            .watch(desktopInventoryCatalogUseCaseProvider)
            .filterAndSort(products: catalog.products, query: _query);
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              flex: 5,
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 24, 24, 12),
                    child: TextField(
                      controller: _searchController,
                      onChanged: (value) =>
                          setState(() => _query = value.trim()),
                      decoration: const InputDecoration(
                        labelText: 'Buscar producto',
                        prefixIcon: Icon(Icons.search),
                      ),
                    ),
                  ),
                  Expanded(
                    child: ListView.separated(
                      padding: const EdgeInsets.fromLTRB(24, 0, 12, 24),
                      itemCount: products.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 8),
                      itemBuilder: (context, index) {
                        final item = products[index];
                        return Card(
                          child: ListTile(
                            title: Text(item.product.nombre),
                            subtitle: Text(
                              '${item.formattedStock} · S/ ${item.mainPrice.toStringAsFixed(2)}',
                            ),
                            trailing: IconButton.filledTonal(
                              tooltip: 'Agregar al carrito',
                              onPressed: _processing
                                  ? null
                                  : () => _addProduct(item, catalog.warehouses),
                              icon: const Icon(Icons.add_shopping_cart),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
            const VerticalDivider(width: 1),
            Expanded(
              flex: 5,
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            'Venta',
                            style: Theme.of(context).textTheme.headlineSmall
                                ?.copyWith(fontWeight: FontWeight.w800),
                          ),
                        ),
                        SizedBox(
                          width: 190,
                          child: DropdownButtonFormField<String>(
                            initialValue: _documentType,
                            decoration: const InputDecoration(
                              labelText: 'Comprobante',
                            ),
                            items: const [
                              DropdownMenuItem(
                                value: 'ticket_interno',
                                child: Text('Ticket Interno'),
                              ),
                              DropdownMenuItem(
                                value: 'boleta',
                                child: Text('Boleta'),
                              ),
                              DropdownMenuItem(
                                value: 'factura',
                                child: Text('Factura'),
                              ),
                            ],
                            onChanged: _processing
                                ? null
                                : (value) => setState(
                                    () =>
                                        _documentType = value ?? _documentType,
                                  ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _customerNameController,
                      decoration: const InputDecoration(labelText: 'Cliente'),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _customerDocumentController,
                            decoration: const InputDecoration(
                              labelText: 'DNI/RUC',
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: TextField(
                            controller: _customerAddressController,
                            decoration: const InputDecoration(
                              labelText: 'Dirección',
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: DropdownButtonFormField<String>(
                            initialValue: _paymentMethod,
                            decoration: const InputDecoration(
                              labelText: 'Pago',
                            ),
                            items: const [
                              DropdownMenuItem(
                                value: 'yape',
                                child: Text('Yape'),
                              ),
                              DropdownMenuItem(
                                value: 'plin',
                                child: Text('Plin'),
                              ),
                              DropdownMenuItem(
                                value: 'transferencia',
                                child: Text('Transferencia'),
                              ),
                              DropdownMenuItem(
                                value: 'efectivo',
                                child: Text('Efectivo'),
                              ),
                            ],
                            onChanged: _processing
                                ? null
                                : (value) {
                                    if (value != null) {
                                      setState(() => _paymentMethod = value);
                                    }
                                  },
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: SwitchListTile.adaptive(
                            contentPadding: EdgeInsets.zero,
                            title: const Text('Venta al crédito'),
                            value: _credit,
                            onChanged: _processing
                                ? null
                                : (value) => setState(() {
                                    _credit = value;
                                    if (!value) {
                                      _downPaymentController.clear();
                                    }
                                  }),
                          ),
                        ),
                      ],
                    ),
                    if (_credit) ...[
                      const SizedBox(height: 8),
                      TextField(
                        controller: _downPaymentController,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        onChanged: (_) => setState(() {}),
                        decoration: const InputDecoration(
                          labelText: 'Abono inicial',
                        ),
                      ),
                    ],
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _discountController,
                            keyboardType: const TextInputType.numberWithOptions(
                              decimal: true,
                            ),
                            onChanged: (_) => setState(() {}),
                            decoration: const InputDecoration(
                              labelText: 'Descuento global S/',
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: TextField(
                            controller: _discountReasonController,
                            decoration: const InputDecoration(
                              labelText: 'Motivo del descuento',
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    Expanded(
                      child: _cart.isEmpty
                          ? const Center(
                              child: Text(
                                'Agrega productos para iniciar la venta.',
                              ),
                            )
                          : ListView.separated(
                              itemCount: _cart.lines.length,
                              separatorBuilder: (_, _) => const Divider(),
                              itemBuilder: (context, index) {
                                final line = _cart.lines[index];
                                final presentation = line
                                    .product
                                    .commercialProfile
                                    .find(line.commercialUnit);
                                return ListTile(
                                  contentPadding: EdgeInsets.zero,
                                  title: Text(line.product.name),
                                  subtitle: Text(
                                    '${CommercialPresentation.formatNumber(line.quantity)} '
                                    '${presentation?.labelFor(line.quantity) ?? line.commercialUnit} '
                                    '· S/ ${line.commercialUnitPrice.toStringAsFixed(2)}',
                                  ),
                                  trailing: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(
                                        'S/ ${line.subtotal.toStringAsFixed(2)}',
                                      ),
                                      IconButton(
                                        tooltip: 'Quitar',
                                        onPressed: _processing
                                            ? null
                                            : () => setState(
                                                () =>
                                                    _cart = _cart.removeProduct(
                                                      line.productId,
                                                    ),
                                              ),
                                        icon: const Icon(Icons.delete_outline),
                                      ),
                                    ],
                                  ),
                                );
                              },
                            ),
                    ),
                    const Divider(),
                    Row(
                      children: [
                        Text('Subtotal: S/ ${_grossTotal.toStringAsFixed(2)}'),
                        const Spacer(),
                        if (_discount > 0)
                          Text('- S/ ${_discount.toStringAsFixed(2)}'),
                        const SizedBox(width: 18),
                        Text(
                          'Total S/ ${_netTotal.toStringAsFixed(2)}',
                          style: Theme.of(context).textTheme.headlineSmall
                              ?.copyWith(fontWeight: FontWeight.w800),
                        ),
                      ],
                    ),
                    if (_credit)
                      Align(
                        alignment: Alignment.centerRight,
                        child: Text(
                          'Saldo: S/ ${(_netTotal - _downPayment).toStringAsFixed(2)}',
                        ),
                      ),
                    const SizedBox(height: 14),
                    SizedBox(
                      height: 48,
                      child: FilledButton.icon(
                        onPressed: _cart.isEmpty || _processing
                            ? null
                            : _submitSale,
                        icon: _processing
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.point_of_sale),
                        label: Text(
                          _processing
                              ? 'Procesando...'
                              : 'Procesar ${_documentType == 'ticket_interno'
                                    ? 'Ticket Interno'
                                    : _documentType == 'boleta'
                                    ? 'Boleta'
                                    : 'Factura'}',
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
