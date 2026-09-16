import 'package:core_logic/features/facturacion/application/electronic_document_use_case.dart';
import 'package:core_logic/features/facturacion/data/supabase_electronic_document_gateway.dart';
import 'package:core_logic/utils/error_mapper.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

final desktopElectronicDocumentUseCaseProvider =
    Provider<ElectronicDocumentUseCase>(
      (ref) => ElectronicDocumentUseCase(
        SupabaseElectronicDocumentGateway(Supabase.instance.client),
      ),
    );

class DesktopDocumentsPanel extends ConsumerStatefulWidget {
  const DesktopDocumentsPanel({super.key});

  @override
  ConsumerState<DesktopDocumentsPanel> createState() =>
      _DesktopDocumentsPanelState();
}

class _DesktopDocumentsPanelState extends ConsumerState<DesktopDocumentsPanel> {
  final _search = TextEditingController();
  DateTimeRange _range = DateTimeRange(
    start: DateTime(DateTime.now().year, DateTime.now().month, 1),
    end: DateTime.now(),
  );
  String _category = 'todos';
  List<ElectronicDocumentRecord> _documents = const [];
  bool _loading = true;
  String? _error;
  bool _acting = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final documents = await ref
          .read(desktopElectronicDocumentUseCaseProvider)
          .list(start: _range.start, end: _range.end, pageSize: 100);
      if (!mounted) return;
      setState(() {
        _documents = documents;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = ErrorMapper.map(error);
      });
    }
  }

  List<ElectronicDocumentRecord> get _filtered {
    final query = _search.text.trim().toLowerCase();
    return _documents
        .where((document) {
          if (_category != 'todos' && document.category != _category)
            return false;
          return query.isEmpty || document.searchableText.contains(query);
        })
        .toList(growable: false);
  }

  Future<void> _selectRange() async {
    final range = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: DateTime.now(),
      initialDateRange: _range,
    );
    if (range == null) return;
    setState(() => _range = range);
    await _load();
  }

  Future<void> _action(
    ElectronicDocumentRecord document, {
    required bool retry,
  }) async {
    if (_acting) return;
    setState(() => _acting = true);
    try {
      final useCase = ref.read(desktopElectronicDocumentUseCaseProvider);
      final result = retry
          ? await useCase.retry(document)
          : await useCase.consult(document, consultSunat: true);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            result.message?.trim().isNotEmpty == true
                ? result.message!
                : 'Estado: ${result.status}',
          ),
        ),
      );
      await _load();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(ErrorMapper.map(error))));
    } finally {
      if (mounted) setState(() => _acting = false);
    }
  }

  Color _statusColor(BuildContext context, String status) {
    final colors = Theme.of(context).colorScheme;
    return switch (status) {
      'aceptado' => Colors.green,
      'rechazado' => colors.error,
      'resultado_incierto' => Colors.orange,
      _ => colors.secondary,
    };
  }

  @override
  Widget build(BuildContext context) {
    final rows = _filtered;
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
                      'Facturación',
                      style: Theme.of(context).textTheme.headlineMedium
                          ?.copyWith(fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 5),
                    const Text(
                      'Consulta y reconciliación de documentos electrónicos.',
                    ),
                  ],
                ),
              ),
              OutlinedButton.icon(
                onPressed: _loading || _acting ? null : _selectRange,
                icon: const Icon(Icons.date_range),
                label: Text(
                  '${_range.start.day}/${_range.start.month}/${_range.start.year} – '
                  '${_range.end.day}/${_range.end.month}/${_range.end.year}',
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filledTonal(
                tooltip: 'Actualizar',
                onPressed: _loading || _acting ? null : _load,
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(28, 0, 28, 16),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _search,
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search),
                    hintText: 'Buscar número, cliente o estado',
                  ),
                ),
              ),
              const SizedBox(width: 12),
              SizedBox(
                width: 190,
                child: DropdownButtonFormField<String>(
                  initialValue: _category,
                  decoration: const InputDecoration(labelText: 'Tipo'),
                  items: const [
                    DropdownMenuItem(value: 'todos', child: Text('Todos')),
                    DropdownMenuItem(value: 'factura', child: Text('Facturas')),
                    DropdownMenuItem(value: 'boleta', child: Text('Boletas')),
                    DropdownMenuItem(
                      value: 'nota',
                      child: Text('Notas de crédito'),
                    ),
                    DropdownMenuItem(value: 'guia', child: Text('Guías')),
                  ],
                  onChanged: (value) =>
                      setState(() => _category = value ?? 'todos'),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _error != null
              ? Center(child: Text(_error!))
              : rows.isEmpty
              ? const Center(
                  child: Text('No hay documentos para el filtro seleccionado.'),
                )
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(28, 0, 28, 28),
                  itemCount: rows.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (context, index) {
                    final document = rows[index];
                    final total = document.total;
                    return Card(
                      child: ListTile(
                        leading: Icon(switch (document.category) {
                          'factura' => Icons.receipt_long,
                          'boleta' => Icons.receipt_outlined,
                          'nota' => Icons.assignment_return_outlined,
                          'guia' => Icons.local_shipping_outlined,
                          _ => Icons.description_outlined,
                        }),
                        title: Text(
                          '${document.typeLabel} · ${document.number}',
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                        subtitle: Text(
                          [
                            if (document.party.isNotEmpty) document.party,
                            document.sunatDescription ?? document.status,
                            if (total != null) 'S/ ${total.toStringAsFixed(2)}',
                          ].join(' · '),
                        ),
                        trailing: Wrap(
                          spacing: 8,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Chip(
                              label: Text(document.status),
                              side: BorderSide(
                                color: _statusColor(context, document.status),
                              ),
                            ),
                            OutlinedButton.icon(
                              onPressed: _acting
                                  ? null
                                  : () => _action(document, retry: false),
                              icon: const Icon(Icons.sync),
                              label: const Text('Consultar'),
                            ),
                            if (document.status != 'aceptado')
                              FilledButton.tonalIcon(
                                onPressed: _acting
                                    ? null
                                    : () => _action(document, retry: true),
                                icon: const Icon(Icons.replay),
                                label: const Text('Reintentar'),
                              ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}
