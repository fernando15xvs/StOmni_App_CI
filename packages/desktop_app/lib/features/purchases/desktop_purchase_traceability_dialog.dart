import 'package:core_logic/core_logic.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

Future<PurchaseReceiptLine?> buildDesktopTraceablePurchaseReceiptLine({
  required BuildContext context,
  required WidgetRef ref,
  required PurchaseOrderLine line,
  required double quantity,
}) async {
  final config = await ref
      .read(inventoryTraceabilityUseCaseProvider)
      .loadConfig(line.productId);
  final profile = await ref.read(businessProfileGatewayProvider).load();
  final active = switch (config.mode) {
    ProductTraceabilityMode.none => false,
    ProductTraceabilityMode.lot => profile.capabilities.lotTracking,
    ProductTraceabilityMode.serial => profile.capabilities.serialNumberTracking,
  };
  if (!active) {
    return PurchaseReceiptLine(
      purchaseOrderLineId: line.id,
      baseQuantity: quantity,
    );
  }
  if (!context.mounted) return null;

  final controller = TextEditingController();
  final accepted = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(
        config.mode == ProductTraceabilityMode.lot
            ? 'Lotes · ${line.productName}'
            : 'Series · ${line.productName}',
      ),
      content: SizedBox(
        width: 620,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              config.mode == ProductTraceabilityMode.lot
                  ? 'Una línea por lote: CODIGO | CANTIDAD${config.expiryRequired ? ' | AAAA-MM-DD' : ' | AAAA-MM-DD opcional'}.'
                  : 'Una serie por línea. Cantidad esperada: ${quantity.round()}.',
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              autofocus: true,
              minLines: 6,
              maxLines: 12,
              decoration: InputDecoration(
                hintText: config.mode == ProductTraceabilityMode.lot
                    ? 'LOTE-A | 5 | 2027-12-31'
                    : 'SN-0001\nSN-0002',
                border: const OutlineInputBorder(),
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
          onPressed: () => Navigator.pop(dialogContext, true),
          child: const Text('Aceptar'),
        ),
      ],
    ),
  );

  if (accepted != true) {
    controller.dispose();
    return null;
  }

  try {
    if (config.mode == ProductTraceabilityMode.serial) {
      if (quantity != quantity.roundToDouble()) {
        throw const FormatException(
          'Una recepción seriada requiere cantidad entera.',
        );
      }
      final serials = controller.text
          .split(RegExp(r'[\r\n]+'))
          .map((value) => value.trim())
          .where((value) => value.isNotEmpty)
          .toList(growable: false);
      if (serials.length != quantity.round() ||
          serials.map((value) => value.toLowerCase()).toSet().length !=
              serials.length) {
        throw FormatException(
          'Debes ingresar ${quantity.round()} series únicas.',
        );
      }
      return PurchaseReceiptLine(
        purchaseOrderLineId: line.id,
        baseQuantity: quantity,
        serials: serials.map(SerialReceiptAllocation.new),
      );
    }

    final lots = <LotReceiptAllocation>[];
    final codes = <String>{};
    var total = 0.0;
    for (final rawLine in controller.text.split(RegExp(r'[\r\n]+'))) {
      final text = rawLine.trim();
      if (text.isEmpty) continue;
      final parts = text.split('|').map((part) => part.trim()).toList();
      if (parts.length < 2 || parts.length > 3) {
        throw const FormatException('Formato de lote inválido.');
      }
      final code = parts[0];
      final qty = double.tryParse(parts[1].replaceAll(',', '.'));
      final expiry = parts.length == 3 && parts[2].isNotEmpty
          ? DateTime.tryParse(parts[2])
          : null;
      if (code.isEmpty ||
          qty == null ||
          qty <= 0 ||
          !codes.add(code.toLowerCase()) ||
          (config.expiryRequired && expiry == null)) {
        throw const FormatException(
          'Hay un lote inválido, repetido o sin vencimiento.',
        );
      }
      total += qty;
      lots.add(
        LotReceiptAllocation(
          lotCode: code,
          baseQuantity: qty,
          expiryDate: expiry,
        ),
      );
    }
    if (lots.isEmpty || (total - quantity).abs() > 0.000001) {
      throw FormatException(
        'Los lotes deben sumar ${CommercialPresentation.formatNumber(quantity)}.',
      );
    }
    return PurchaseReceiptLine(
      purchaseOrderLineId: line.id,
      baseQuantity: quantity,
      lots: lots,
    );
  } finally {
    controller.dispose();
  }
}
