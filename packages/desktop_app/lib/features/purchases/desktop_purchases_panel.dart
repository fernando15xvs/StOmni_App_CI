import 'package:core_logic/core_logic.dart';
import 'package:core_logic/features/compras/domain/purchase_order.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../inventory/desktop_inventory_controller.dart';
import 'desktop_purchase_providers.dart';
import 'desktop_purchase_traceability_dialog.dart';

class _PurchaseLineDraftState {
  _PurchaseLineDraftState(this.item)
    : quantity = TextEditingController(),
      cost = TextEditingController(
        text: CommercialPresentation.formatNumber(item.product.precioCompra),
      );

  final DesktopInventoryItem item;
  final TextEditingController quantity;
  final TextEditingController cost;

  void dispose() {
    quantity.dispose();
    cost.dispose();
  }
}

class DesktopPurchasesPanel extends ConsumerStatefulWidget {
  const DesktopPurchasesPanel({super.key});

  @override
  ConsumerState<DesktopPurchasesPanel> createState() =>
      _DesktopPurchasesPanelState();
}

class _DesktopPurchasesPanelState extends ConsumerState<DesktopPurchasesPanel> {
  bool _mutating = false;

  void _refresh() {
    ref.invalidate(desktopPurchaseOrdersProvider);
    ref.invalidate(desktopInventorySnapshotProvider);
  }

  String _status(PurchaseOrderStatus status) => switch (status) {
    PurchaseOrderStatus.draft => 'Borrador',
    PurchaseOrderStatus.ordered => 'Ordenada',
    PurchaseOrderStatus.partiallyReceived => 'Recepción parcial',
    PurchaseOrderStatus.received => 'Recibida',
    PurchaseOrderStatus.cancelled => 'Anulada',
  };

  Future<void> _createOrder(
    InventoryCatalogSnapshot inventory,
    List<SupplierRecord> suppliers,
  ) async {
    final warehouses = inventory.warehouses.where((row) => row.active).toList();
    final products = inventory.products
        .where((row) => row.active)
        .map(DesktopInventoryItem.new)
        .toList();
    if (suppliers.isEmpty || warehouses.isEmpty || products.isEmpty) {
      _message(
        'Necesitas proveedores, almacenes y productos activos para crear una compra.',
        error: true,
      );
      return;
    }

    var supplierId = suppliers.first.id;
    var warehouseId = warehouses.first.id;
    InventoryCatalogItem selected = inventory.products.firstWhere(
      (row) => row.active,
    );
    final lines = <_PurchaseLineDraftState>[];
    final notes = TextEditingController();

    final accepted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) {
          void addLine() {
            if (lines.any(
              (line) => line.item.product.id == selected.product.id,
            ))
              return;
            setDialogState(
              () => lines.add(
                _PurchaseLineDraftState(DesktopInventoryItem(selected)),
              ),
            );
          }

          return AlertDialog(
            title: const Text('Nueva orden de compra'),
            content: SizedBox(
              width: 780,
              height: 560,
              child: Column(
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: DropdownButtonFormField<int>(
                          initialValue: supplierId,
                          decoration: const InputDecoration(
                            labelText: 'Proveedor',
                          ),
                          items: suppliers
                              .map(
                                (supplier) => DropdownMenuItem(
                                  value: supplier.id,
                                  child: Text(
                                    supplier.name,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              )
                              .toList(),
                          onChanged: (value) {
                            if (value != null)
                              setDialogState(() => supplierId = value);
                          },
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: DropdownButtonFormField<int>(
                          initialValue: warehouseId,
                          decoration: const InputDecoration(
                            labelText: 'Almacén de recepción',
                          ),
                          items: warehouses
                              .map(
                                (warehouse) => DropdownMenuItem(
                                  value: warehouse.id,
                                  child: Text(warehouse.name),
                                ),
                              )
                              .toList(),
                          onChanged: (value) {
                            if (value != null)
                              setDialogState(() => warehouseId = value);
                          },
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      Expanded(
                        child: DropdownButtonFormField<int>(
                          initialValue: selected.product.id,
                          decoration: const InputDecoration(
                            labelText: 'Agregar producto',
                          ),
                          items: products
                              .map(
                                (item) => DropdownMenuItem(
                                  value: item.product.id,
                                  child: Text(
                                    item.product.nombre,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              )
                              .toList(),
                          onChanged: (id) {
                            if (id == null) return;
                            setDialogState(() {
                              selected = inventory.products.firstWhere(
                                (row) => row.product.id == id,
                              );
                            });
                          },
                        ),
                      ),
                      const SizedBox(width: 8),
                      FilledButton.icon(
                        onPressed: addLine,
                        icon: const Icon(Icons.add),
                        label: const Text('Agregar'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Expanded(
                    child: lines.isEmpty
                        ? const Center(
                            child: Text(
                              'Agrega los productos que deseas solicitar.',
                            ),
                          )
                        : ListView.separated(
                            itemCount: lines.length,
                            separatorBuilder: (_, _) => const Divider(),
                            itemBuilder: (context, index) {
                              final line = lines[index];
                              final base = line.item.basePresentation;
                              return Row(
                                children: [
                                  Expanded(
                                    flex: 3,
                                    child: Text(line.item.product.nombre),
                                  ),
                                  const SizedBox(width: 8),
                                  SizedBox(
                                    width: 150,
                                    child: TextField(
                                      controller: line.quantity,
                                      keyboardType:
                                          TextInputType.numberWithOptions(
                                            decimal: base.quantityPrecision > 0,
                                          ),
                                      decoration: InputDecoration(
                                        labelText:
                                            'Cantidad (${base.pluralLabel})',
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  SizedBox(
                                    width: 130,
                                    child: TextField(
                                      controller: line.cost,
                                      keyboardType:
                                          const TextInputType.numberWithOptions(
                                            decimal: true,
                                          ),
                                      decoration: const InputDecoration(
                                        labelText: 'Costo unitario',
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
                              );
                            },
                          ),
                  ),
                  TextField(
                    controller: notes,
                    maxLines: 2,
                    decoration: const InputDecoration(
                      labelText: 'Notas (opcional)',
                    ),
                  ),
                ],
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
                        try {
                          for (final line in lines) {
                            final quantity = double.parse(
                              line.quantity.text.trim().replaceAll(',', '.'),
                            );
                            final cost = double.parse(
                              line.cost.text.trim().replaceAll(',', '.'),
                            );
                            line.item.basePresentation.commercialQuantity(
                              quantity,
                            );
                            if (quantity <= 0 || cost < 0) return;
                          }
                          Navigator.pop(dialogContext, true);
                        } catch (_) {
                          return;
                        }
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
            .read(desktopPurchaseOrderUseCaseProvider)
            .create(
              PurchaseOrderDraft(
                requestId: const Uuid().v4(),
                supplierId: supplierId,
                warehouseId: warehouseId,
                orderedAt: AppTime.now(),
                notes: notes.text.trim(),
                lines: lines
                    .map(
                      (line) => PurchaseOrderLineDraft(
                        productId: line.item.product.id,
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
    final controllers = <int, TextEditingController>{
      for (final line in order.lines.where(
        (line) => line.pendingBaseQuantity > 0,
      ))
        line.id: TextEditingController(),
    };
    final document = TextEditingController();
    final notes = TextEditingController();
    final accepted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Recibir OC #${order.id}'),
        content: SizedBox(
          width: 650,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final line in order.lines.where(
                  (line) => line.pendingBaseQuantity > 0,
                )) ...[
                  Row(
                    children: [
                      Expanded(child: Text(line.productName)),
                      const SizedBox(width: 8),
                      Text(
                        'Pendiente: ${CommercialPresentation.formatNumber(line.pendingBaseQuantity)}',
                      ),
                      const SizedBox(width: 12),
                      SizedBox(
                        width: 130,
                        child: TextField(
                          controller: controllers[line.id],
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          decoration: const InputDecoration(
                            labelText: 'Recibir',
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                ],
                TextField(
                  controller: document,
                  decoration: const InputDecoration(
                    labelText: 'Documento / factura proveedor',
                  ),
                ),
                const SizedBox(height: 10),
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
              for (final line in order.lines) {
                final raw =
                    controllers[line.id]?.text.trim().replaceAll(',', '.') ??
                    '';
                if (raw.isEmpty) continue;
                final value = double.tryParse(raw);
                if (value == null ||
                    value <= 0 ||
                    value > line.pendingBaseQuantity + 1e-7)
                  return;
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
        for (final line in order.lines) {
          final raw =
              controllers[line.id]?.text.trim().replaceAll(',', '.') ?? '';
          if (raw.isEmpty) continue;
          final value = double.tryParse(raw);
          if (value == null || value <= 0) continue;
          final receiptLine = await buildDesktopTraceablePurchaseReceiptLine(
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
            .read(desktopPurchaseOrderUseCaseProvider)
            .receive(
              ReceivePurchaseOrderCommand(
                requestId: const Uuid().v4(),
                purchaseOrderId: order.id,
                receivedAt: AppTime.now(),
                document: document.text.trim(),
                notes: notes.text.trim(),
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

    for (final controller in controllers.values) {
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
            .read(desktopPurchaseOrderUseCaseProvider)
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

  void _message(String message, {bool error = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: error ? Theme.of(context).colorScheme.error : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final orders = ref.watch(desktopPurchaseOrdersProvider);
    final inventory = ref.watch(desktopInventorySnapshotProvider);
    final suppliers = ref.watch(desktopPurchaseSuppliersProvider);

    return Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Compras',
                      style: Theme.of(context).textTheme.headlineMedium
                          ?.copyWith(fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 5),
                    const Text(
                      'Órdenes de proveedor y recepción transaccional hacia inventario.',
                    ),
                  ],
                ),
              ),
              FilledButton.icon(
                onPressed: _mutating
                    ? null
                    : inventory.maybeWhen(
                        data: (catalog) => suppliers.maybeWhen(
                          data: (rows) =>
                              () => _createOrder(catalog, rows),
                          orElse: () => null,
                        ),
                        orElse: () => null,
                      ),
                icon: const Icon(Icons.add_shopping_cart),
                label: const Text('Nueva orden'),
              ),
              const SizedBox(width: 8),
              IconButton.filledTonal(
                onPressed: _mutating ? null : _refresh,
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
          const SizedBox(height: 18),
          Expanded(
            child: orders.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (error, _) => Center(
                child: Text(
                  ErrorMapper.map(error),
                  textAlign: TextAlign.center,
                ),
              ),
              data: (rows) => rows.isEmpty
                  ? const Center(
                      child: Text('Todavía no hay órdenes de compra.'),
                    )
                  : ListView.separated(
                      itemCount: rows.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 8),
                      itemBuilder: (context, index) {
                        final order = rows[index];
                        return Card(
                          child: ExpansionTile(
                            title: Text(
                              'OC #${order.id} · ${order.supplierName}',
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            subtitle: Text(
                              '${_status(order.status)} · ${order.warehouseName} · ${AppFormatters.currency(order.total)}',
                            ),
                            trailing: Wrap(
                              spacing: 8,
                              children: [
                                if (order.canReceive)
                                  OutlinedButton.icon(
                                    onPressed: _mutating
                                        ? null
                                        : () => _receive(order),
                                    icon: const Icon(
                                      Icons.inventory_2_outlined,
                                    ),
                                    label: const Text('Recibir'),
                                  ),
                                if (order.status == PurchaseOrderStatus.ordered)
                                  IconButton(
                                    tooltip: 'Anular',
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
        ],
      ),
    );
  }
}
