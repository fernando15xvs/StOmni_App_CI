import 'dart:async';

import 'package:core_logic/core_logic.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import 'desktop_inventory_controller.dart';

class DesktopInventoryPanel extends ConsumerStatefulWidget {
  const DesktopInventoryPanel({super.key});

  @override
  ConsumerState<DesktopInventoryPanel> createState() =>
      _DesktopInventoryPanelState();
}

class _DesktopInventoryPanelState extends ConsumerState<DesktopInventoryPanel> {
  final _searchController = TextEditingController();
  Timer? _debounce;
  String _query = '';
  bool _mutating = false;

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  void _onSearchChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () {
      if (!mounted) return;
      setState(() => _query = value.trim());
    });
  }

  void _refresh() {
    ref.invalidate(desktopInventorySnapshotProvider);
  }

  String _formatQuantity(double value) =>
      CommercialPresentation.formatNumber(value);

  double _warehouseStock(Producto product, int warehouseId) {
    for (final stock in product.inventario) {
      if (stock.almacenId == warehouseId) return stock.cantidad;
    }
    return 0;
  }

  TextInputFormatter _quantityFormatter(int precision) {
    return TextInputFormatter.withFunction((oldValue, newValue) {
      final normalized = newValue.text.replaceAll(',', '.');
      final pattern = RegExp('^\\d*(?:\\.\\d{0,$precision})?\$');
      if (!pattern.hasMatch(normalized)) return oldValue;
      return newValue.copyWith(
        text: normalized,
        selection: TextSelection.collapsed(offset: normalized.length),
      );
    });
  }

  Future<void> _registerEntry(
    DesktopInventoryItem item,
    List<InventoryWarehouseRecord> warehouses,
  ) async {
    final active = warehouses.where((warehouse) => warehouse.active).toList();
    if (active.isEmpty) {
      _message('No hay almacenes activos disponibles.', error: true);
      return;
    }
    var warehouseId = active.first.id;
    var adjustment = false;
    final quantity = TextEditingController();
    final document = TextEditingController();
    final observations = TextEditingController();
    final base = item.basePresentation;

    final accepted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text('Ingreso · ${item.product.nombre}'),
          content: SizedBox(
            width: 470,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<int>(
                  initialValue: warehouseId,
                  decoration: const InputDecoration(labelText: 'Almacén'),
                  items: active
                      .map(
                        (warehouse) => DropdownMenuItem(
                          value: warehouse.id,
                          child: Text(warehouse.name),
                        ),
                      )
                      .toList(),
                  onChanged: (value) {
                    if (value != null) {
                      setDialogState(() => warehouseId = value);
                    }
                  },
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: quantity,
                  keyboardType: TextInputType.numberWithOptions(
                    decimal: base.quantityPrecision > 0,
                  ),
                  inputFormatters: [_quantityFormatter(base.quantityPrecision)],
                  decoration: InputDecoration(
                    labelText: 'Cantidad (${base.pluralLabel})',
                  ),
                ),
                const SizedBox(height: 14),
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Ajuste de inventario'),
                  subtitle: Text(
                    adjustment
                        ? 'Requiere permiso de ajuste.'
                        : 'Se registrará como compra/ingreso.',
                  ),
                  value: adjustment,
                  onChanged: (value) =>
                      setDialogState(() => adjustment = value),
                ),
                TextField(
                  controller: document,
                  decoration: const InputDecoration(
                    labelText: 'Documento (opcional)',
                  ),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: observations,
                  maxLines: 2,
                  decoration: const InputDecoration(labelText: 'Observaciones'),
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
              onPressed: () {
                final value = double.tryParse(
                  quantity.text.trim().replaceAll(',', '.'),
                );
                if (value == null || !value.isFinite || value <= 0) return;
                try {
                  FixedQuantity.fromDouble(
                    value,
                    scale: base.quantityPrecision,
                  );
                } on ArgumentError {
                  return;
                }
                Navigator.pop(dialogContext, true);
              },
              child: const Text('Registrar'),
            ),
          ],
        ),
      ),
    );

    if (accepted != true || !mounted) {
      quantity.dispose();
      document.dispose();
      observations.dispose();
      return;
    }

    final parsed = double.parse(quantity.text.trim().replaceAll(',', '.'));
    setState(() => _mutating = true);
    try {
      await ref.read(desktopRegisterMerchandiseEntryUseCaseProvider)(
        MerchandiseEntryCommand(
          requestId: const Uuid().v4(),
          productId: item.product.id,
          date: AppTime.now(),
          entryType: adjustment ? 'Ajuste de Inventario' : 'Compra',
          document: document.text.trim(),
          supplierId: item.product.proveedorId,
          observations: observations.text.trim(),
          warehouses: [
            MerchandiseWarehouseAllocation(
              warehouseId: warehouseId,
              baseQuantity: parsed,
            ),
          ],
          cost: item.product.precioCompra,
          unitPrice: item.product.precioUnidad,
          boxPrice: item.product.precioCaja ?? 0,
          comparativeBoxPrice: (item.product.precioCaja ?? 0) > 0
              ? (item.product.precioCaja ?? 0) *
                    (item.product.cantidadPorCaja ?? 1)
              : item.product.precioUnidad * (item.product.cantidadPorCaja ?? 1),
        ),
      );
      if (!mounted) return;
      _message('Ingreso registrado correctamente.');
      _refresh();
    } catch (error) {
      if (mounted) _message(ErrorMapper.map(error), error: true);
    } finally {
      quantity.dispose();
      document.dispose();
      observations.dispose();
      if (mounted) setState(() => _mutating = false);
    }
  }

  Future<void> _registerMovement(
    DesktopInventoryItem item,
    List<InventoryWarehouseRecord> warehouses,
  ) async {
    final active = warehouses.where((warehouse) => warehouse.active).toList();
    if (active.isEmpty) {
      _message('No hay almacenes activos disponibles.', error: true);
      return;
    }
    var sourceId = active.first.id;
    var destinationId = active.length > 1 ? active[1].id : null;
    var waste = false;
    final quantity = TextEditingController();
    final reason = TextEditingController();
    final base = item.basePresentation;

    final accepted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) {
          final available = _warehouseStock(item.product, sourceId);
          return AlertDialog(
            title: Text('Movimiento · ${item.product.nombre}'),
            content: SizedBox(
              width: 480,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SegmentedButton<bool>(
                    segments: const [
                      ButtonSegment(value: false, label: Text('Traslado')),
                      ButtonSegment(value: true, label: Text('Merma')),
                    ],
                    selected: {waste},
                    onSelectionChanged: (values) =>
                        setDialogState(() => waste = values.first),
                  ),
                  const SizedBox(height: 16),
                  DropdownButtonFormField<int>(
                    initialValue: sourceId,
                    decoration: const InputDecoration(labelText: 'Origen'),
                    items: active
                        .map(
                          (warehouse) => DropdownMenuItem(
                            value: warehouse.id,
                            child: Text(warehouse.name),
                          ),
                        )
                        .toList(),
                    onChanged: (value) {
                      if (value == null) return;
                      setDialogState(() {
                        sourceId = value;
                        if (destinationId == sourceId) {
                          destinationId = active
                              .where((warehouse) => warehouse.id != sourceId)
                              .map((warehouse) => warehouse.id)
                              .firstOrNull;
                        }
                      });
                    },
                  ),
                  const SizedBox(height: 6),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'Disponible: ${_formatQuantity(available)} ${base.pluralLabel}',
                    ),
                  ),
                  if (!waste) ...[
                    const SizedBox(height: 14),
                    DropdownButtonFormField<int>(
                      initialValue: destinationId,
                      decoration: const InputDecoration(labelText: 'Destino'),
                      items: active
                          .where((warehouse) => warehouse.id != sourceId)
                          .map(
                            (warehouse) => DropdownMenuItem(
                              value: warehouse.id,
                              child: Text(warehouse.name),
                            ),
                          )
                          .toList(),
                      onChanged: (value) =>
                          setDialogState(() => destinationId = value),
                    ),
                  ],
                  const SizedBox(height: 14),
                  TextField(
                    controller: quantity,
                    keyboardType: TextInputType.numberWithOptions(
                      decimal: base.quantityPrecision > 0,
                    ),
                    inputFormatters: [
                      _quantityFormatter(base.quantityPrecision),
                    ],
                    decoration: InputDecoration(
                      labelText: 'Cantidad (${base.pluralLabel})',
                    ),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: reason,
                    maxLines: 2,
                    decoration: InputDecoration(
                      labelText: waste
                          ? 'Motivo de merma (obligatorio)'
                          : 'Motivo (opcional)',
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
                onPressed: () {
                  final value = double.tryParse(
                    quantity.text.trim().replaceAll(',', '.'),
                  );
                  if (value == null || value <= 0 || value > available + 1e-7) {
                    return;
                  }
                  if (waste && reason.text.trim().isEmpty) return;
                  if (!waste && destinationId == null) return;
                  try {
                    FixedQuantity.fromDouble(
                      value,
                      scale: base.quantityPrecision,
                    );
                  } on ArgumentError {
                    return;
                  }
                  Navigator.pop(dialogContext, true);
                },
                child: const Text('Confirmar'),
              ),
            ],
          );
        },
      ),
    );

    if (accepted != true || !mounted) {
      quantity.dispose();
      reason.dispose();
      return;
    }

    final parsed = double.parse(quantity.text.trim().replaceAll(',', '.'));
    setState(() => _mutating = true);
    try {
      await ref.read(desktopRegisterStockMovementUseCaseProvider)(
        RegisterStockMovementCommand(
          requestId: const Uuid().v4(),
          productId: item.product.id,
          quantity: parsed,
          sourceWarehouseId: sourceId,
          destinationWarehouseId: waste ? null : destinationId,
          isWaste: waste,
          reason: reason.text.trim(),
        ),
      );
      if (!mounted) return;
      _message(waste ? 'Merma registrada.' : 'Traslado registrado.');
      _refresh();
    } catch (error) {
      if (mounted) _message(ErrorMapper.map(error), error: true);
    } finally {
      quantity.dispose();
      reason.dispose();
      if (mounted) setState(() => _mutating = false);
    }
  }

  void _message(String message, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: error ? Theme.of(context).colorScheme.error : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final inventory = ref.watch(desktopInventoryProvider(_query));
    final snapshot = ref.watch(desktopInventorySnapshotProvider);

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(28, 24, 28, 16),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Inventario',
                      style: Theme.of(context).textTheme.headlineMedium
                          ?.copyWith(fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 5),
                    const Text(
                      'Consulta, ingresos, ajustes, traslados y mermas sobre el mismo core compartido.',
                    ),
                  ],
                ),
              ),
              IconButton.filledTonal(
                tooltip: 'Recargar inventario',
                onPressed: _mutating ? null : _refresh,
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(28, 0, 28, 16),
          child: TextField(
            controller: _searchController,
            onChanged: _onSearchChanged,
            decoration: InputDecoration(
              hintText: 'Buscar por nombre, código o código de barras…',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: _searchController.text.isEmpty
                  ? null
                  : IconButton(
                      tooltip: 'Limpiar búsqueda',
                      onPressed: () {
                        _debounce?.cancel();
                        _searchController.clear();
                        setState(() => _query = '');
                      },
                      icon: const Icon(Icons.clear),
                    ),
            ),
          ),
        ),
        Expanded(
          child: inventory.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (error, _) =>
                _InventoryError(error: error.toString(), onRetry: _refresh),
            data: (items) => snapshot.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (error, _) =>
                  _InventoryError(error: error.toString(), onRetry: _refresh),
              data: (catalog) {
                if (items.isEmpty) {
                  return Center(
                    child: Text(
                      _query.isEmpty
                          ? 'No hay productos disponibles.'
                          : 'No se encontraron productos para “$_query”.',
                    ),
                  );
                }

                return ListView.separated(
                  padding: const EdgeInsets.fromLTRB(28, 0, 28, 28),
                  itemCount: items.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (context, index) {
                    final item = items[index];
                    final product = item.product;
                    return Card(
                      child: ListTile(
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 18,
                          vertical: 8,
                        ),
                        leading: CircleAvatar(
                          child: Text(
                            product.nombre.isEmpty
                                ? '?'
                                : product.nombre.characters.first.toUpperCase(),
                          ),
                        ),
                        title: Text(
                          product.nombre,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                        subtitle: Padding(
                          padding: const EdgeInsets.only(top: 5),
                          child: Wrap(
                            spacing: 14,
                            runSpacing: 4,
                            children: [
                              Text('Código: ${item.codeLabel}'),
                              Text(item.supplierLabel),
                              Text(item.saleTypeLabel),
                              Text(
                                '${_formatQuantity(item.totalStock)} ${item.basePresentation.pluralLabel}',
                              ),
                            ],
                          ),
                        ),
                        trailing: Wrap(
                          spacing: 8,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            OutlinedButton.icon(
                              onPressed: _mutating
                                  ? null
                                  : () => _registerEntry(
                                      item,
                                      catalog.warehouses,
                                    ),
                              icon: const Icon(Icons.add_box_outlined),
                              label: const Text('Ingreso'),
                            ),
                            OutlinedButton.icon(
                              onPressed: _mutating
                                  ? null
                                  : () => _registerMovement(
                                      item,
                                      catalog.warehouses,
                                    ),
                              icon: const Icon(Icons.swap_horiz),
                              label: const Text('Mover'),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}

class _InventoryError extends StatelessWidget {
  const _InventoryError({required this.error, required this.onRetry});

  final String error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Card(
          margin: const EdgeInsets.all(28),
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.inventory_2_outlined, size: 44),
                const SizedBox(height: 14),
                const Text(
                  'No se pudo cargar el inventario',
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 18),
                ),
                const SizedBox(height: 10),
                Text(error, textAlign: TextAlign.center),
                const SizedBox(height: 18),
                FilledButton.icon(
                  onPressed: onRetry,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Reintentar'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
