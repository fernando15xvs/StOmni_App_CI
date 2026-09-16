import 'package:core_logic/core_logic.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'desktop_inventory_controller.dart';
import 'desktop_product_admin.dart';

class _UnitDraft {
  _UnitDraft(CommercialPresentation source)
    : code = TextEditingController(text: source.code),
      singular = TextEditingController(text: source.singularLabel),
      plural = TextEditingController(text: source.pluralLabel),
      factor = TextEditingController(
        text: CommercialPresentation.formatNumber(source.baseQuantity),
      ),
      fiscal = TextEditingController(text: source.fiscalUnitCode ?? ''),
      precision = source.quantityPrecision;

  _UnitDraft.empty(int index)
    : code = TextEditingController(text: 'presentacion_$index'),
      singular = TextEditingController(text: 'Presentación'),
      plural = TextEditingController(text: 'Presentaciones'),
      factor = TextEditingController(text: '1'),
      fiscal = TextEditingController(),
      precision = 0;

  final TextEditingController code;
  final TextEditingController singular;
  final TextEditingController plural;
  final TextEditingController factor;
  final TextEditingController fiscal;
  int precision;

  void dispose() {
    code.dispose();
    singular.dispose();
    plural.dispose();
    factor.dispose();
    fiscal.dispose();
  }
}

class DesktopProductUnitsEditor extends ConsumerStatefulWidget {
  const DesktopProductUnitsEditor({super.key, required this.item});

  final DesktopInventoryItem item;

  @override
  ConsumerState<DesktopProductUnitsEditor> createState() =>
      _DesktopProductUnitsEditorState();
}

class _DesktopProductUnitsEditorState
    extends ConsumerState<DesktopProductUnitsEditor> {
  late final String _baseCode;
  late final List<_UnitDraft> _rows;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final profile = widget.item.catalogItem.commercialProfile;
    _baseCode = profile.baseUnit.code;
    _rows = profile.presentations.map(_UnitDraft.new).toList();
  }

  @override
  void dispose() {
    for (final row in _rows) {
      row.dispose();
    }
    super.dispose();
  }

  double _factor(_UnitDraft row) =>
      double.tryParse(row.factor.text.trim().replaceAll(',', '.')) ??
      double.nan;

  ProductUnitProfile _profile() {
    final presentations = _rows
        .map((row) {
          final normalizedCode = CommercialPresentation.normalizeCode(
            row.code.text,
          );
          return CommercialPresentation(
            code: normalizedCode,
            singularLabel: row.singular.text.trim(),
            pluralLabel: row.plural.text.trim(),
            baseQuantity: normalizedCode == _baseCode ? 1 : _factor(row),
            fiscalUnitCode: row.fiscal.text,
            quantityPrecision: row.precision,
          );
        })
        .toList(growable: false);
    final base = presentations.where((row) => row.code == _baseCode).single;
    return ProductUnitProfile(baseUnit: base, presentations: presentations);
  }

  Future<void> _save(ProductUnitSettings settings) async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final saved = await ref
          .read(desktopSaveProductUnitConfigurationUseCaseProvider)
          .execute(
            productId: widget.item.product.id,
            current: settings,
            profile: _profile(),
          );
      if (!mounted) return;
      ref.invalidate(
        desktopProductUnitSettingsProvider(widget.item.product.id),
      );
      ref.invalidate(desktopInventorySnapshotProvider);
      Navigator.of(context).pop(saved);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.toString())));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(
      desktopProductUnitSettingsProvider(widget.item.product.id),
    );
    return AlertDialog(
      title: Text('Unidades · ${widget.item.product.nombre}'),
      content: SizedBox(
        width: 850,
        height: 540,
        child: settings.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, _) => Center(child: Text(error.toString())),
          data: (current) {
            if (!current.supported) {
              return const Center(
                child: Text(
                  'La base de datos todavía no tiene instaladas las migraciones de presentaciones configurables.',
                  textAlign: TextAlign.center,
                ),
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'La unidad base conserva factor 1. La precisión define los decimales permitidos y el código fiscal se usa en documentos electrónicos/GRE.',
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: ListView.separated(
                    itemCount: _rows.length,
                    separatorBuilder: (_, _) => const Divider(height: 24),
                    itemBuilder: (context, index) {
                      final row = _rows[index];
                      final isBase =
                          CommercialPresentation.normalizeCode(row.code.text) ==
                          _baseCode;
                      return Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: TextField(
                              controller: row.code,
                              readOnly: isBase,
                              decoration: InputDecoration(
                                labelText: isBase ? 'Código base' : 'Código',
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: TextField(
                              controller: row.singular,
                              decoration: const InputDecoration(
                                labelText: 'Singular',
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: TextField(
                              controller: row.plural,
                              decoration: const InputDecoration(
                                labelText: 'Plural',
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          SizedBox(
                            width: 105,
                            child: TextField(
                              controller: row.factor,
                              readOnly: isBase,
                              keyboardType:
                                  const TextInputType.numberWithOptions(
                                    decimal: true,
                                  ),
                              decoration: const InputDecoration(
                                labelText: 'Factor',
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          SizedBox(
                            width: 105,
                            child: DropdownButtonFormField<int>(
                              initialValue: row.precision,
                              decoration: const InputDecoration(
                                labelText: 'Dec.',
                              ),
                              items: List.generate(
                                FixedQuantity.maxScale + 1,
                                (value) => DropdownMenuItem(
                                  value: value,
                                  child: Text('$value'),
                                ),
                              ),
                              onChanged: (value) => setState(
                                () => row.precision = value ?? row.precision,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          SizedBox(
                            width: 105,
                            child: TextField(
                              controller: row.fiscal,
                              textCapitalization: TextCapitalization.characters,
                              decoration: const InputDecoration(
                                labelText: 'Fiscal',
                              ),
                            ),
                          ),
                          const SizedBox(width: 4),
                          IconButton(
                            tooltip: isBase
                                ? 'La unidad base no se elimina'
                                : 'Eliminar presentación',
                            onPressed: isBase || _saving
                                ? null
                                : () {
                                    setState(() {
                                      final removed = _rows.removeAt(index);
                                      removed.dispose();
                                    });
                                  },
                            icon: const Icon(Icons.delete_outline),
                          ),
                        ],
                      );
                    },
                  ),
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(
                    onPressed: _saving || _rows.length >= 20
                        ? null
                        : () => setState(
                            () => _rows.add(_UnitDraft.empty(_rows.length + 1)),
                          ),
                    icon: const Icon(Icons.add),
                    label: const Text('Agregar presentación'),
                  ),
                ),
              ],
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('Cerrar'),
        ),
        settings.maybeWhen(
          data: (current) => current.supported
              ? FilledButton.icon(
                  onPressed: _saving ? null : () => _save(current),
                  icon: _saving
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.save_outlined),
                  label: const Text('Guardar unidades'),
                )
              : const SizedBox.shrink(),
          orElse: () => const SizedBox.shrink(),
        ),
      ],
    );
  }
}
