import 'package:core_logic/core_logic.dart';
import 'package:core_logic/features/compras/domain/purchase_order.dart';
import 'package:core_logic/features/shared/models/producto_busqueda.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../providers/compras_provider.dart';
import '../widgets/purchase_traceability_dialog.dart';

class _MobilePurchaseLineDraft {
  _MobilePurchaseLineDraft(this.product)
    : quantity = TextEditingController(),
      cost = TextEditingController();

  final ProductoBusqueda product;
  final TextEditingController quantity;
  final TextEditingController cost;

  void dispose() {
    quantity.dispose();
    cost.dispose();
  }
}

class ComprasPage extends ConsumerStatefulWidget {
  const ComprasPage({super.key});

  @override
  ConsumerState<ComprasPage> createState() => _ComprasPageState();
}

class _ComprasPageState extends ConsumerState<ComprasPage> {
  bool _mutating = false;

  void _refresh() {
    ref.invalidate(purchaseOrdersProvider);
    ref.invalidate(purchaseCatalogProvider);
  }

  String _status(PurchaseOrderStatus status) => switch (status) {
    PurchaseOrderStatus.draft => 'Borrador',
    PurchaseOrderStatus.ordered => 'Ordenada',
    PurchaseOrderStatus.partiallyReceived => 'Parcial',
    PurchaseOrderStatus.received => 'Recibida',
    PurchaseOrderStatus.cancelled => 'Anulada',
  };

  Future<void> _create() async {
    final catalog = await ref.read(purchaseCatalogProvider.future);
    final allProducts = await ref.read(
      purchaseProductSearchProvider('').future,
    );
    if (!mounted) return;
    final products = allProducts
        .where((row) => row.activo)
        .toList(growable: false);
    if (catalog.activeSuppliers.isEmpty ||
        catalog.warehouses.isEmpty ||
        products.isEmpty) {
      _message('Necesitas proveedor, almacén y producto activos.', error: true);
      return;
    }

    var supplierId = catalog.activeSuppliers.first.id;
    var warehouseId = catalog.warehouses.first.id;
    var selectedProductId = products.first.id;
    final lines = <_MobilePurchaseLineDraft>[];
    final notes = TextEditingController();

    final accepted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) {
          void addProduct() {
            if (lines.any((line) => line.product.id == selectedProductId))
              return;
            final product = products.firstWhere(
              (row) => row.id == selectedProductId,
            );
            setDialogState(() => lines.add(_MobilePurchaseLineDraft(product)));
          }

          return AlertDialog(
            title: const Text('Nueva orden de compra'),
            content: SizedBox(
              width: 560,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    DropdownButtonFormField<int>(
                      initialValue: supplierId,
                      isExpanded: true,
                      decoration: const InputDecoration(labelText: 'Proveedor'),
                      items: catalog.activeSuppliers
                          .map(
                            (row) => DropdownMenuItem(
                              value: row.id,
                              child: Text(row.name),
                            ),
                          )
                          .toList(),
                      onChanged: (value) {
                        if (value != null)
                          setDialogState(() => supplierId = value);
                      },
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<int>(
                      initialValue: warehouseId,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'Almacén de recepción',
                      ),
                      items: catalog.warehouses
                          .map(
                            (row) => DropdownMenuItem(
                              value: row.id,
                              child: Text(row.name),
                            ),
                          )
                          .toList(),
                      onChanged: (value) {
                        if (value != null)
                          setDialogState(() => warehouseId = value);
                      },
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: DropdownButtonFormField<int>(
                            initialValue: selectedProductId,
                            isExpanded: true,
                            decoration: const InputDecoration(
                              labelText: 'Producto',
                            ),
                            items: products
                                .map(
                                  (row) => DropdownMenuItem(
                                    value: row.id,
                                    child: Text(
                                      row.nombre,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                )
                                .toList(),
                            onChanged: (value) {
                              if (value != null) {
                                setDialogState(() => selectedProductId = value);
                              }
                            },
                          ),
                        ),
                        const SizedBox(width: 8),
                        IconButton.filledTonal(
                          tooltip: 'Agregar producto',
                          onPressed: addProduct,
                          icon: const Icon(Icons.add),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    if (lines.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 20),
                        child: Text('Agrega uno o más productos a la orden.'),
                      )
                    else
                      ...List.generate(lines.length, (index) {
                        final line = lines[index];
                        return Card(
                          margin: const EdgeInsets.only(bottom: 10),
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        line.product.nombre,
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                    ),
                                    IconButton(
                                      tooltip: 'Quitar',
                                      onPressed: () => setDialogState(() {
                                        final removed = lines.removeAt(index);
                                        removed.dispose();
                                      }),
                                      icon: const Icon(Icons.delete_outline),
                                    ),
                                  ],
                                ),
                                TextField(
                                  controller: line.quantity,
                                  keyboardType:
                                      const TextInputType.numberWithOptions(
                                        decimal: true,
                                      ),
                                  decoration: const InputDecoration(
                                    labelText: 'Cantidad en unidad base',
                                  ),
                                ),
                                const SizedBox(height: 8),
                                TextField(
                                  controller: line.cost,
                                  keyboardType:
                                      const TextInputType.numberWithOptions(
                                        decimal: true,
                                      ),
                                  decoration: const InputDecoration(
                                    labelText: 'Costo por unidad base',
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      }),
                    TextField(
                      controller: notes,
                      maxLines: 2,
                      decoration: const InputDecoration(labelText: 'Notas'),
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('Cancelar'),
              ),
              FilledButton(
                onPressed: lines.isEmpty
                    ? null
                    : () {
                        for (final line in lines) {
                          final quantity = double.tryParse(
                            line.quantity.text.trim().replaceAll(',', '.'),
                          );
                          final cost = double.tryParse(
                            line.cost.text.trim().replaceAll(',', '.'),
                          );
                          if (quantity == null ||
                              quantity <= 0 ||
                              cost == null ||
                              cost < 0) {
                            return;
                          }
                        }
                        Navigator.pop(dialogContext, true);
                      },
                child: const Text('Crear orden'),
              ),
            ],
          );
        },
      ),
    );

    if (accepted == true && mounted) {
      setState(() => _mutating = true);
      try {
        await ref
            .read(purchaseOrderUseCaseProvider)
            .create(
              PurchaseOrderDraft(
                requestId: const Uuid().v4(),
                supplierId: supplierId,
                warehouseId: warehouseId,
                orderedAt: AppTime.now(),
                notes: notes.text,
                lines: lines
                    .map(
                      (line) => PurchaseOrderLineDraft(
                        productId: line.product.id,
                        baseQuantity: double.parse(
                          line.quantity.text.trim().replaceAll(',', '.'),
                        ),
                        unitCost: double.parse(
                          line.cost.text.trim().replaceAll(',', '.'),
                        ),
                      ),
                    )
                    .toList(growable: false),
              ),
            );
        if (mounted) {
          _message('Orden de compra creada.');
          _refresh();
        }
      } catch (error) {
        if (mounted) _message(ErrorMapper.map(error), error: true);
      } finally {
        if (mounted) setState(() => _mutating = false);
      }
    }
    for (final line in lines) {
      line.dispose();
    }
    notes.dispose();
  }

  Future<void> _receive(PurchaseOrderRecord order) async {
    final pending = order.lines
        .where((line) => line.pendingBaseQuantity > 0)
        .toList();
    if (pending.isEmpty) return;
    final quantities = <int, TextEditingController>{
      for (final line in pending) line.id: TextEditingController(),
    };
    final document = TextEditingController();
    final notes = TextEditingController();

    final accepted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Recibir OC #${order.id}'),
        content: SizedBox(
          width: 560,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final line in pending) ...[
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '${line.productName} · pendiente ${CommercialPresentation.formatNumber(line.pendingBaseQuantity)}',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                  TextField(
                    controller: quantities[line.id],
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: const InputDecoration(
                      labelText: 'Cantidad recibida',
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                TextField(
                  controller: document,
                  decoration: const InputDecoration(
                    labelText: 'Documento proveedor',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: notes,
                  maxLines: 2,
                  decoration: const InputDecoration(labelText: 'Observaciones'),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () {
              var hasQuantity = false;
              for (final line in pending) {
                final raw = quantities[line.id]!.text.trim().replaceAll(
                  ',',
                  '.',
                );
                if (raw.isEmpty) continue;
                final value = double.tryParse(raw);
                if (value == null ||
                    value <= 0 ||
                    value > line.pendingBaseQuantity + 1e-7) {
                  return;
                }
                hasQuantity = true;
              }
              if (hasQuantity) Navigator.pop(dialogContext, true);
            },
            child: const Text('Continuar'),
          ),
        ],
      ),
    );

    if (accepted == true && mounted) {
      try {
        final receiptLines = <PurchaseReceiptLine>[];
        for (final line in pending) {
          final raw = quantities[line.id]!.text.trim().replaceAll(',', '.');
          if (raw.isEmpty) continue;
          final value = double.parse(raw);
          final receiptLine = await buildTraceablePurchaseReceiptLine(
            context: context,
            ref: ref,
            line: line,
            quantity: value,
          );
          if (receiptLine == null) return;
          receiptLines.add(receiptLine);
        }
        if (!mounted) return;
        setState(() => _mutating = true);
        await ref
            .read(purchaseOrderUseCaseProvider)
            .receive(
              ReceivePurchaseOrderCommand(
                requestId: const Uuid().v4(),
                purchaseOrderId: order.id,
                receivedAt: AppTime.now(),
                document: document.text,
                notes: notes.text,
                lines: receiptLines,
              ),
            );
        if (mounted) {
          _message('Recepción registrada e inventario actualizado.');
          _refresh();
        }
      } catch (error) {
        if (mounted) _message(ErrorMapper.map(error), error: true);
      } finally {
        if (mounted) setState(() => _mutating = false);
      }
    }
    for (final controller in quantities.values) {
      controller.dispose();
    }
    document.dispose();
    notes.dispose();
  }

  Future<void> _cancel(PurchaseOrderRecord order) async {
    final reason = TextEditingController();
    final accepted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Anular OC #${order.id}'),
        content: TextField(
          controller: reason,
          maxLines: 2,
          decoration: const InputDecoration(labelText: 'Motivo de anulación'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Volver'),
          ),
          FilledButton(
            onPressed: () {
              if (reason.text.trim().isNotEmpty)
                Navigator.pop(dialogContext, true);
            },
            child: const Text('Anular'),
          ),
        ],
      ),
    );
    if (accepted == true && mounted) {
      setState(() => _mutating = true);
      try {
        await ref
            .read(purchaseOrderUseCaseProvider)
            .cancel(order.id, reason: reason.text);
        if (mounted) {
          _message('Orden anulada.');
          _refresh();
        }
      } catch (error) {
        if (mounted) _message(ErrorMapper.map(error), error: true);
      } finally {
        if (mounted) setState(() => _mutating = false);
      }
    }
    reason.dispose();
  }

  void _message(String text, {bool error = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(text), backgroundColor: error ? Colors.red : null),
    );
  }

  @override
  Widget build(BuildContext context) {
    final orders = ref.watch(purchaseOrdersProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Compras')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _mutating ? null : _create,
        icon: const Icon(Icons.add_shopping_cart),
        label: const Text('Nueva orden'),
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          _refresh();
          await ref.read(purchaseOrdersProvider.future);
        },
        child: orders.when(
          loading: () => ListView(
            children: const [
              SizedBox(height: 280),
              Center(child: CircularProgressIndicator()),
            ],
          ),
          error: (error, _) => ListView(
            children: [
              const SizedBox(height: 180),
              Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  ErrorMapper.map(error),
                  textAlign: TextAlign.center,
                ),
              ),
            ],
          ),
          data: (rows) => rows.isEmpty
              ? ListView(
                  children: const [
                    SizedBox(height: 220),
                    Center(child: Text('No hay órdenes de compra.')),
                  ],
                )
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
                  itemCount: rows.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 10),
                  itemBuilder: (context, index) {
                    final order = rows[index];
                    return Card(
                      child: ExpansionTile(
                        title: Text('OC #${order.id} · ${order.supplierName}'),
                        subtitle: Text(
                          '${_status(order.status)} · ${AppFormatters.currency(order.total)}',
                        ),
                        trailing: Wrap(
                          spacing: 4,
                          children: [
                            if (order.canReceive)
                              IconButton(
                                tooltip: 'Recibir mercadería',
                                onPressed: _mutating
                                    ? null
                                    : () => _receive(order),
                                icon: const Icon(Icons.inventory_2_outlined),
                              ),
                            if (order.status == PurchaseOrderStatus.ordered)
                              IconButton(
                                tooltip: 'Anular orden',
                                onPressed: _mutating
                                    ? null
                                    : () => _cancel(order),
                                icon: const Icon(Icons.cancel_outlined),
                              ),
                          ],
                        ),
                        children: [
                          for (final line in order.lines)
                            ListTile(
                              dense: true,
                              title: Text(line.productName),
                              subtitle: Text(
                                'Pedido ${CommercialPresentation.formatNumber(line.orderedBaseQuantity)} · recibido ${CommercialPresentation.formatNumber(line.receivedBaseQuantity)}',
                              ),
                              trailing: Text(
                                AppFormatters.currency(line.orderedAmount),
                              ),
                            ),
                        ],
                      ),
                    );
                  },
                ),
        ),
      ),
    );
  }
}
