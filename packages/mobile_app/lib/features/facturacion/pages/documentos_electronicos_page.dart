import 'package:core_logic/core_logic.dart';
import 'package:core_logic/features/facturacion/application/electronic_document_use_case.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/widgets/estado_tributario_badge.dart';
import '../../../core/widgets/global_date_filter.dart';
import '../../ventas/pages/ver_venta_page.dart';
import '../providers/electronic_document_use_case_provider.dart';
import 'gestion_tributaria_page.dart';
import 'nueva_guia_remision_page.dart';
import 'ver_guia_remision_page.dart';
import 'ver_nota_credito_page.dart';

class DocumentosElectronicosPage extends ConsumerStatefulWidget {
  const DocumentosElectronicosPage({super.key});

  @override
  ConsumerState<DocumentosElectronicosPage> createState() =>
      _DocumentosElectronicosPageState();
}

class _DocumentosElectronicosPageState
    extends ConsumerState<DocumentosElectronicosPage> {
  static const _filtros = <String, String>{
    'todos': 'Todos',
    'guia': 'Guías',
    'factura': 'Facturas',
    'boleta': 'Boletas',
    'nota': 'Notas',
  };
  static const int _porPagina = 50;

  final _buscarCtrl = TextEditingController();
  final GlobalDateFilterState _dateFilter = GlobalDateFilterState(
    filtroTipo: 'Mensual',
  );

  bool _cargando = true;
  bool _cargandoMas = false;
  bool _hayMas = true;
  bool _accionando = false;
  int _pagina = 0;
  String _filtro = 'todos';
  String? _error;
  List<ElectronicDocumentRecord> _documentos = const [];

  Color get _color => Colors.deepPurple;

  @override
  void initState() {
    super.initState();
    _buscarCtrl.addListener(_refrescarVista);
    _cargar();
  }

  @override
  void dispose() {
    _buscarCtrl
      ..removeListener(_refrescarVista)
      ..dispose();
    super.dispose();
  }

  void _refrescarVista() {
    if (mounted) setState(() {});
  }

  Future<void> _cargar({bool reiniciar = true}) async {
    if (reiniciar) {
      if (mounted) {
        setState(() {
          _cargando = true;
          _pagina = 0;
          _hayMas = true;
          _error = null;
        });
      }
    } else {
      if (_cargandoMas || !_hayMas) return;
      if (mounted) setState(() => _cargandoMas = true);
    }

    try {
      final paginaSolicitada = reiniciar ? 0 : _pagina + 1;
      final data = await ref.read(electronicDocumentUseCaseProvider).list(
            start: _dateFilter.fechaInicio,
            end: _dateFilter.fechaFin,
            page: paginaSolicitada,
            pageSize: _porPagina,
          );
      if (!mounted) return;
      setState(() {
        if (reiniciar) {
          _documentos = data;
        } else {
          final existing = _documentos
              .map((row) => '${row.category}:${row.id}')
              .toSet();
          _documentos = [
            ..._documentos,
            ...data.where(
              (row) => existing.add('${row.category}:${row.id}'),
            ),
          ];
        }
        _pagina = paginaSolicitada;
        _hayMas = data.length == _porPagina;
        _cargando = false;
        _cargandoMas = false;
        _error = null;
      });
    } catch (error) {
      if (!mounted) return;
      final message = ErrorMapper.map(error);
      setState(() {
        _cargando = false;
        _cargandoMas = false;
        if (reiniciar) _error = message;
      });
      if (!reiniciar) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(message), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _cargarMas() => _cargar(reiniciar: false);

  List<ElectronicDocumentRecord> get _filtrados {
    final query = _buscarCtrl.text.trim().toLowerCase();
    return _documentos.where((document) {
      if (_filtro != 'todos' && document.category != _filtro) return false;
      return query.isEmpty || document.searchableText.contains(query);
    }).toList(growable: false);
  }

  Future<void> _abrirDocumento(ElectronicDocumentRecord document) async {
    Widget? page;
    switch (document.category) {
      case 'guia':
        page = VerGuiaRemisionPage(guiaId: document.id);
        break;
      case 'nota':
        page = VerNotaCreditoPage(notaCreditoId: document.id);
        break;
      case 'factura':
      case 'boleta':
        if (document.saleId != null) {
          page = VerVentaPage(ventaId: document.saleId!);
        }
        break;
    }
    if (page == null || !mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => page!));
    if (mounted) await _cargar();
  }

  Future<void> _accion(
    ElectronicDocumentRecord document, {
    required bool reintentar,
  }) async {
    if (_accionando) return;
    setState(() => _accionando = true);
    try {
      final useCase = ref.read(electronicDocumentUseCaseProvider);
      final result = reintentar
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
      await _cargar();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(ErrorMapper.map(error)),
          backgroundColor: Colors.red,
        ),
      );
    } finally {
      if (mounted) setState(() => _accionando = false);
    }
  }

  Future<void> _nuevaGuia() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const NuevaGuiaRemisionPage()),
    );
    if (mounted) await _cargar();
  }

  Future<void> _abrirProcesos() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const GestionTributariaPage()),
    );
    if (mounted) await _cargar();
  }

  void _seleccionarFechaEspecifica() {
    GlobalDateFilterWidget.seleccionarFechaEspecifica(
      context: context,
      filterState: _dateFilter,
      primaryColor: _color,
      onSelected: (date) {
        setState(() => _dateFilter.fechaEspecifica = date);
        _cargar();
      },
    );
  }

  void _seleccionarRango() {
    GlobalDateFilterWidget.seleccionarRango(
      context: context,
      primaryColor: _color,
      onSelected: (range) {
        setState(() {
          _dateFilter.filtroTipo = 'Personalizado';
          _dateFilter.rangoPersonalizado = range;
        });
        _cargar();
      },
    );
  }

  IconData _icon(ElectronicDocumentRecord document) => switch (document.category) {
        'factura' => Icons.receipt_long,
        'boleta' => Icons.receipt_outlined,
        'nota' => Icons.assignment_return_outlined,
        'guia' => Icons.local_shipping_outlined,
        _ => Icons.description_outlined,
      };

  @override
  Widget build(BuildContext context) {
    final esAdmin = ref.watch(rolProvider) == 'admin';
    final documents = _filtrados;

    return Scaffold(
      appBar: AppBar(
        backgroundColor: _color,
        foregroundColor: Colors.white,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Documentos Electrónicos',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            GlobalDateFilterWidget.buildTitleWidget(
              filterState: _dateFilter,
              onSelectFechaEspecifica: _seleccionarFechaEspecifica,
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Actualizar',
            onPressed: _cargando || _accionando ? null : () => _cargar(),
            icon: const Icon(Icons.refresh),
          ),
          if (esAdmin)
            PopupMenuButton<String>(
              onSelected: (value) {
                if (value == 'guia') _nuevaGuia();
                if (value == 'procesos') _abrirProcesos();
                if (value == 'rango') _seleccionarRango();
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'guia', child: Text('Nueva guía de remisión')),
                PopupMenuItem(value: 'procesos', child: Text('Gestión tributaria')),
                PopupMenuItem(value: 'rango', child: Text('Rango personalizado')),
              ],
            ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: TextField(
              controller: _buscarCtrl,
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: 'Buscar número, cliente o estado',
              ),
            ),
          ),
          SizedBox(
            height: 52,
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              scrollDirection: Axis.horizontal,
              children: _filtros.entries
                  .map(
                    (entry) => Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: ChoiceChip(
                        label: Text(entry.value),
                        selected: _filtro == entry.key,
                        onSelected: (_) => setState(() => _filtro = entry.key),
                      ),
                    ),
                  )
                  .toList(growable: false),
            ),
          ),
          Expanded(
            child: _cargando
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(_error!, textAlign: TextAlign.center),
                              const SizedBox(height: 12),
                              FilledButton.icon(
                                onPressed: _cargar,
                                icon: const Icon(Icons.refresh),
                                label: const Text('Reintentar'),
                              ),
                            ],
                          ),
                        ),
                      )
                    : RefreshIndicator(
                        onRefresh: _cargar,
                        child: documents.isEmpty
                            ? ListView(
                                physics: const AlwaysScrollableScrollPhysics(),
                                children: const [
                                  SizedBox(height: 180),
                                  Center(child: Text('No hay documentos para este filtro.')),
                                ],
                              )
                            : ListView.builder(
                                physics: const AlwaysScrollableScrollPhysics(),
                                padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
                                itemCount: documents.length + (_hayMas ? 1 : 0),
                                itemBuilder: (context, index) {
                                  if (index == documents.length) {
                                    return Padding(
                                      padding: const EdgeInsets.all(16),
                                      child: Center(
                                        child: _cargandoMas
                                            ? const CircularProgressIndicator()
                                            : OutlinedButton.icon(
                                                onPressed: _cargarMas,
                                                icon: const Icon(Icons.expand_more),
                                                label: const Text('Cargar más'),
                                              ),
                                      ),
                                    );
                                  }
                                  final document = documents[index];
                                  return Card(
                                    margin: const EdgeInsets.only(bottom: 10),
                                    child: ListTile(
                                      onTap: () => _abrirDocumento(document),
                                      leading: CircleAvatar(child: Icon(_icon(document))),
                                      title: Text(
                                        '${document.typeLabel} · ${document.number}',
                                        style: const TextStyle(fontWeight: FontWeight.bold),
                                      ),
                                      subtitle: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          if (document.party.isNotEmpty) Text(document.party),
                                          if (document.sunatDescription?.isNotEmpty == true)
                                            Text(
                                              document.sunatDescription!,
                                              maxLines: 2,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          const SizedBox(height: 5),
                                          EstadoTributarioBadge(estado: document.status),
                                        ],
                                      ),
                                      trailing: PopupMenuButton<String>(
                                        enabled: !_accionando,
                                        onSelected: (value) {
                                          if (value == 'consultar') {
                                            _accion(document, reintentar: false);
                                          } else if (value == 'reintentar') {
                                            _accion(document, reintentar: true);
                                          }
                                        },
                                        itemBuilder: (_) => [
                                          const PopupMenuItem(
                                            value: 'consultar',
                                            child: Text('Consultar estado'),
                                          ),
                                          if (document.status != 'aceptado')
                                            const PopupMenuItem(
                                              value: 'reintentar',
                                              child: Text('Reintentar envío'),
                                            ),
                                        ],
                                      ),
                                    ),
                                  );
                                },
                              ),
                      ),
          ),
        ],
      ),
      floatingActionButton: esAdmin
          ? FloatingActionButton.extended(
              backgroundColor: _color,
              foregroundColor: Colors.white,
              onPressed: _nuevaGuia,
              icon: const Icon(Icons.local_shipping_outlined),
              label: const Text('Nueva guía'),
            )
          : null,
    );
  }
}
