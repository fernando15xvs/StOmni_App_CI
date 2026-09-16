import 'package:core_logic/core_logic.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/product_unit_configuration_providers.dart';

class ProductUnitConfigurationPage extends ConsumerStatefulWidget {
  const ProductUnitConfigurationPage({
    super.key,
    required this.productId,
    required this.productName,
    required this.legacyProfile,
  });

  final int productId;
  final String productName;
  final ProductUnitProfile legacyProfile;

  @override
  ConsumerState<ProductUnitConfigurationPage> createState() =>
      _ProductUnitConfigurationPageState();
}

class _ProductUnitConfigurationPageState
    extends ConsumerState<ProductUnitConfigurationPage> {
  ProductUnitSettings? _settings;
  final List<_UnitDraft> _units = [];
  int _baseIndex = 0;
  Object? _loadError;
  bool _busy = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _busy = true;
      _loadError = null;
    });
    try {
      final settings = await ref
          .read(productUnitConfigurationGatewayProvider)
          .load(widget.productId);
      if (!mounted) return;
      final effectiveProfile =
          settings.configuration?.profile ?? widget.legacyProfile;
      setState(() {
        _settings = settings;
        _units
          ..clear()
          ..addAll(
            effectiveProfile.presentations.map(
              (presentation) => _UnitDraft.fromPresentation(presentation),
            ),
          );
        _baseIndex = _units.indexWhere(
          (unit) => unit.code.text.trim() == effectiveProfile.baseUnit.code,
        );
        if (_baseIndex < 0) _baseIndex = 0;
        _busy = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loadError = error;
        _busy = false;
      });
    }
  }

  Future<void> _save() async {
    final settings = _settings;
    if (_busy || _units.isEmpty || settings == null) return;
    setState(() => _busy = true);
    try {
      final presentations = <CommercialPresentation>[];
      for (var index = 0; index < _units.length; index++) {
        final draft = _units[index];
        final code = draft.code.text.trim();
        final singular = draft.singular.text.trim();
        final plural = draft.plural.text.trim();
        final factor = double.tryParse(
          draft.factor.text.trim().replaceAll(',', '.'),
        );
        final precision = int.tryParse(draft.precision.text.trim());
        final fiscalUnit = draft.fiscalUnit.text.trim();
        if (code.isEmpty ||
            singular.isEmpty ||
            plural.isEmpty ||
            factor == null ||
            !factor.isFinite ||
            factor <= 0 ||
            precision == null ||
            precision < 0 ||
            precision > 6) {
          throw const FormatException(
            'Completa códigos, etiquetas, equivalencias y precisión válidas.',
          );
        }
        presentations.add(
          CommercialPresentation(
            code: code,
            singularLabel: singular,
            pluralLabel: plural,
            baseQuantity: factor,
            quantityPrecision: precision,
            fiscalUnitCode: fiscalUnit.isEmpty ? null : fiscalUnit,
          ),
        );
      }
      final profile = ProductUnitProfile(
        baseUnit: presentations[_baseIndex],
        presentations: presentations,
      );
      PresentationPolicy.validate(profile);
      await ref
          .read(saveProductUnitConfigurationUseCaseProvider)
          .execute(
            productId: widget.productId,
            current: settings,
            profile: profile,
          );
      await ref.read(refreshProductUnitCatalogProvider)(widget.productId);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Unidades y presentaciones actualizadas.'),
        ),
      );
      await _load();
    } catch (error) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(ErrorMapper.map(error)),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  void _addUnit() {
    setState(() {
      _units.add(_UnitDraft.empty());
    });
  }

  void _removeUnit(int index) {
    if (_units.length <= 1) return;
    setState(() {
      final removed = _units.removeAt(index);
      removed.dispose();
      if (_baseIndex == index) {
        _baseIndex = 0;
      } else if (_baseIndex > index) {
        _baseIndex--;
      }
    });
  }

  @override
  void dispose() {
    for (final unit in _units) {
      unit.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Unidades · ${widget.productName}')),
      body: _busy && _settings == null
          ? const Center(child: CircularProgressIndicator())
          : _loadError != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      ErrorMapper.map(_loadError!),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      onPressed: _load,
                      icon: const Icon(Icons.refresh),
                      label: const Text('Reintentar'),
                    ),
                  ],
                ),
              ),
            )
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                const Text(
                  'Define la unidad base real del inventario y las presentaciones comerciales. '
                  'La equivalencia siempre se expresa en cantidad de la unidad base.',
                ),
                const SizedBox(height: 16),
                for (var index = 0; index < _units.length; index++)
                  _unitCard(index),
                OutlinedButton.icon(
                  onPressed: _busy ? null : _addUnit,
                  icon: const Icon(Icons.add),
                  label: const Text('Agregar presentación'),
                ),
                const SizedBox(height: 18),
                FilledButton.icon(
                  onPressed: _busy ? null : _save,
                  icon: _busy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.save),
                  label: Text(_busy ? 'Guardando...' : 'Guardar configuración'),
                ),
              ],
            ),
    );
  }

  Widget _unitCard(int index) {
    final draft = _units[index];
    final isBase = index == _baseIndex;
    return Card(
      margin: const EdgeInsets.only(bottom: 14),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          children: [
            RadioListTile<int>(
              value: index,
              groupValue: _baseIndex,
              onChanged: _busy
                  ? null
                  : (value) {
                      if (value != null) setState(() => _baseIndex = value);
                    },
              title: Text(isBase ? 'Unidad base' : 'Usar como unidad base'),
              contentPadding: EdgeInsets.zero,
            ),
            TextFormField(
              controller: draft.code,
              enabled: !_busy,
              decoration: const InputDecoration(labelText: 'Código interno'),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    controller: draft.singular,
                    enabled: !_busy,
                    decoration: const InputDecoration(labelText: 'Singular'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TextFormField(
                    controller: draft.plural,
                    enabled: !_busy,
                    decoration: const InputDecoration(labelText: 'Plural'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    controller: draft.factor,
                    enabled: !_busy && !isBase,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
                    ],
                    decoration: InputDecoration(
                      labelText: isBase
                          ? 'Equivalencia base'
                          : 'Equivalencia en base',
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TextFormField(
                    controller: draft.precision,
                    enabled: !_busy,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Decimales permitidos',
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            TextFormField(
              controller: draft.fiscalUnit,
              enabled: !_busy,
              textCapitalization: TextCapitalization.characters,
              decoration: const InputDecoration(
                labelText: 'Código fiscal/SUNAT (opcional)',
                hintText: 'NIU, KGM, MTR, BX...',
              ),
            ),
            if (!isBase)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: _busy ? null : () => _removeUnit(index),
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('Quitar'),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _UnitDraft {
  _UnitDraft({
    required this.code,
    required this.singular,
    required this.plural,
    required this.factor,
    required this.precision,
    required this.fiscalUnit,
  });

  factory _UnitDraft.fromPresentation(CommercialPresentation presentation) {
    return _UnitDraft(
      code: TextEditingController(text: presentation.code),
      singular: TextEditingController(text: presentation.singularLabel),
      plural: TextEditingController(text: presentation.pluralLabel),
      factor: TextEditingController(
        text: CommercialPresentation.formatNumber(presentation.baseQuantity),
      ),
      precision: TextEditingController(
        text: presentation.quantityPrecision.toString(),
      ),
      fiscalUnit: TextEditingController(
        text: presentation.fiscalUnitCode ?? '',
      ),
    );
  }

  factory _UnitDraft.empty() {
    return _UnitDraft(
      code: TextEditingController(),
      singular: TextEditingController(),
      plural: TextEditingController(),
      factor: TextEditingController(text: '1'),
      precision: TextEditingController(text: '0'),
      fiscalUnit: TextEditingController(),
    );
  }

  final TextEditingController code;
  final TextEditingController singular;
  final TextEditingController plural;
  final TextEditingController factor;
  final TextEditingController precision;
  final TextEditingController fiscalUnit;

  void dispose() {
    code.dispose();
    singular.dispose();
    plural.dispose();
    factor.dispose();
    precision.dispose();
    fiscalUnit.dispose();
  }
}
