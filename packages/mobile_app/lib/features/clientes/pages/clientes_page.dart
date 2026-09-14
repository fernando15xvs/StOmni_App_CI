import 'dart:async';

import 'package:mobile_app/core/theme/app_colors.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:core_logic/core_logic.dart';
import '../providers/customer_use_case_provider.dart';
import '../widgets/cliente_form_dialog.dart';

class ClientesPage extends ConsumerStatefulWidget {
  const ClientesPage({super.key});

  @override
  ConsumerState<ClientesPage> createState() => _ClientesPageState();
}

class _ClientesPageState extends ConsumerState<ClientesPage> {
  final TextEditingController _searchCtrl = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  List<CustomerRecord> _clientes = [];
  bool _cargandoInicial = true;
  bool _cargandoMas = false;
  bool _hayMas = true;

  static const int _limit = 20;
  int _offset = 0;
  String _query = '';

  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _cargarInicial();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _scrollController.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  void _onScroll() {
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 200) {
      if (!_cargandoMas && _hayMas && !_cargandoInicial) {
        _cargarMas();
      }
    }
  }

  void _onSearchChanged(String query) {
    if (_debounce?.isActive ?? false) _debounce!.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      final normalized = query.trim();
      if (!mounted || _query == normalized) return;
      setState(() => _query = normalized);
      _cargarInicial();
    });
  }

  Future<void> _cargarInicial() async {
    if (!mounted) return;
    setState(() {
      _cargandoInicial = true;
      _offset = 0;
      _hayMas = true;
      _clientes.clear();
    });

    try {
      final data = await ref.read(customerUseCaseProvider).list(
            limit: _limit,
            offset: _offset,
            query: _query,
          );

      if (!mounted) return;
      setState(() {
        _clientes = data;
        _offset += data.length;
        _hayMas = data.length == _limit;
        _cargandoInicial = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _cargandoInicial = false);
      _mostrarError(e);
    }
  }

  Future<void> _cargarMas() async {
    if (!mounted || _cargandoMas || !_hayMas) return;
    setState(() => _cargandoMas = true);

    try {
      final data = await ref.read(customerUseCaseProvider).list(
            limit: _limit,
            offset: _offset,
            query: _query,
          );

      if (!mounted) return;
      setState(() {
        _clientes.addAll(data);
        _offset += data.length;
        _hayMas = data.length == _limit;
        _cargandoMas = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _cargandoMas = false);
      _mostrarError(e);
    }
  }

  void _mostrarError(Object error) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(ErrorMapper.map(error)),
        backgroundColor: Colors.red,
      ),
    );
  }

  void _mostrarDialogoCliente([CustomerRecord? cliente]) {
    showDialog<void>(
      context: context,
      builder: (ctx) => ClienteFormDialog(
        cliente: cliente,
        onSaved: _cargarInicial,
      ),
    );
  }

  Future<void> _eliminar(CustomerRecord customer) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('¿Eliminar Cliente?'),
        content: const Text(
          'Solo se eliminará si nunca fue usado en una operación. Los clientes '
          'con historial se conservan para mantener la trazabilidad.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Eliminar', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    try {
      await ref.read(customerUseCaseProvider).delete(customer.id);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Cliente eliminado'),
          backgroundColor: AppColors.clientes,
        ),
      );
      await _cargarInicial();
    } catch (e) {
      if (!mounted) return;
      final message = ErrorMapper.isConnectionError(e)
          ? ErrorMapper.map(e)
          : 'No se puede eliminar este cliente porque tiene historial asociado.';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message), backgroundColor: Colors.red),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        title: const Text(
          'Directorio de Clientes',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        backgroundColor: AppColors.clientes,
        iconTheme: const IconThemeData(color: Colors.white),
        elevation: 0,
      ),
      body: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            color: AppColors.clientes,
            child: TextField(
              controller: _searchCtrl,
              decoration: InputDecoration(
                hintText: 'Buscar cliente...',
                prefixIcon: const Icon(Icons.search, color: Colors.grey),
                filled: true,
                fillColor: Theme.of(context).brightness == Brightness.dark
                    ? Colors.grey[900]
                    : Colors.white,
                contentPadding: const EdgeInsets.symmetric(vertical: 0),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(30),
                  borderSide: BorderSide.none,
                ),
              ),
              onChanged: _onSearchChanged,
            ),
          ),
          Expanded(
            child: _cargandoInicial
                ? const Center(
                    child: CircularProgressIndicator(color: AppColors.clientes),
                  )
                : RefreshIndicator(
                    onRefresh: _cargarInicial,
                    color: AppColors.clientes,
                    child: _clientes.isEmpty
                        ? ListView(
                            physics: const AlwaysScrollableScrollPhysics(),
                            children: const [
                              SizedBox(height: 200),
                              Center(child: Text('No se encontraron clientes')),
                            ],
                          )
                        : ListView.builder(
                            controller: _scrollController,
                            physics: const AlwaysScrollableScrollPhysics(),
                            itemCount: _clientes.length + (_hayMas ? 1 : 0),
                            padding: const EdgeInsets.fromLTRB(16, 20, 16, 100),
                            itemBuilder: (ctx, i) {
                              if (i == _clientes.length) {
                                return const Center(
                                  child: Padding(
                                    padding: EdgeInsets.all(16),
                                    child: CircularProgressIndicator(
                                      color: AppColors.clientes,
                                    ),
                                  ),
                                );
                              }

                              final customer = _clientes[i];
                              return Container(
                                margin: const EdgeInsets.only(bottom: 12),
                                decoration: BoxDecoration(
                                  color: Theme.of(context).cardColor,
                                  borderRadius: BorderRadius.circular(16),
                                  boxShadow:
                                      Theme.of(context).brightness ==
                                          Brightness.dark
                                      ? []
                                      : [
                                          BoxShadow(
                                            color: Colors.black.withValues(
                                              alpha: 0.05,
                                            ),
                                            blurRadius: 8,
                                            offset: const Offset(0, 4),
                                          ),
                                        ],
                                ),
                                child: ListTile(
                                  contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 16,
                                    vertical: 8,
                                  ),
                                  leading: CircleAvatar(
                                    radius: 24,
                                    backgroundColor:
                                        Theme.of(context).brightness ==
                                            Brightness.dark
                                        ? Colors.blue[900]?.withValues(
                                            alpha: 0.3,
                                          )
                                        : Colors.blue[50],
                                    child: Text(
                                      customer.name.isNotEmpty
                                          ? customer.name[0].toUpperCase()
                                          : 'C',
                                      style: TextStyle(
                                        color:
                                            Theme.of(context).brightness ==
                                                Brightness.dark
                                            ? Colors.blue[200]
                                            : Colors.blue[800],
                                        fontWeight: FontWeight.bold,
                                        fontSize: 18,
                                      ),
                                    ),
                                  ),
                                  title: Text(
                                    customer.name,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 16,
                                    ),
                                  ),
                                  subtitle: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      const SizedBox(height: 4),
                                      Text(
                                        'DOC: ${customer.document.isEmpty ? '-' : customer.document}',
                                        style: TextStyle(
                                          color: Colors.grey[600],
                                          fontSize: 12,
                                        ),
                                      ),
                                      Text(
                                        customer.address.isEmpty
                                            ? '-'
                                            : customer.address,
                                        style: TextStyle(
                                          color: Colors.grey[600],
                                          fontSize: 12,
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ],
                                  ),
                                  trailing: PopupMenuButton<String>(
                                    icon: Icon(
                                      Icons.more_vert,
                                      color: Colors.grey[400],
                                    ),
                                    onSelected: (val) {
                                      if (val == 'edit') {
                                        _mostrarDialogoCliente(customer);
                                      }
                                      if (val == 'delete') {
                                        _eliminar(customer);
                                      }
                                    },
                                    itemBuilder: (context) => const [
                                      PopupMenuItem(
                                        value: 'edit',
                                        child: Row(
                                          children: [
                                            Icon(Icons.edit, size: 20),
                                            SizedBox(width: 10),
                                            Text('Editar'),
                                          ],
                                        ),
                                      ),
                                      PopupMenuItem(
                                        value: 'delete',
                                        child: Row(
                                          children: [
                                            Icon(
                                              Icons.delete,
                                              size: 20,
                                              color: Colors.red,
                                            ),
                                            SizedBox(width: 10),
                                            Text(
                                              'Eliminar',
                                              style: TextStyle(
                                                color: Colors.red,
                                              ),
                                            ),
                                          ],
                                        ),
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
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: AppColors.clientes,
        icon: const Icon(Icons.person_add, color: Colors.white),
        label: const Text(
          'Nuevo Cliente',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        onPressed: () => _mostrarDialogoCliente(),
      ),
    );
  }
}
