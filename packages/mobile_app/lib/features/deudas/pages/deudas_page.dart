import 'package:core_logic/core_logic.dart';
import 'package:mobile_app/core/theme/app_colors.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'detalle_deudas_actor_page.dart';

class DeudasPage extends ConsumerStatefulWidget {
  final int initialTabIndex;

  const DeudasPage({super.key, this.initialTabIndex = 0});

  @override
  ConsumerState<DeudasPage> createState() => _DeudasPageState();
}

class _DeudasPageState extends ConsumerState<DeudasPage>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  bool _cargando = true;
  String? _errorCarga;

  List<Map<String, dynamic>> _gruposPorCobrar = [];
  List<Map<String, dynamic>> _gruposPorPagar = [];

  final Color colorVerde = const Color(0xFF0F9D58);
  final Color colorRojo = const Color(0xFFD32F2F);

  @override
  void initState() {
    super.initState();
    _tabController = TabController(
      length: 2,
      vsync: this,
      initialIndex: widget.initialTabIndex,
    );
    _cargarTodo();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _cargarTodo() async {
    if (mounted) {
      setState(() {
        _cargando = true;
        _errorCarga = null;
      });
    }

    try {
      final data = await ref
          .read(deudasRepositoryProvider)
          .obtenerDeudasActivas();
      final ventasData = data['ventas']!;
      final gastosData = data['gastos']!;

      if (!mounted) return;
      setState(() {
        _gruposPorCobrar = _agruparDatos(
          List<Map<String, dynamic>>.from(ventasData),
          true,
        );
        _gruposPorPagar = _agruparDatos(
          List<Map<String, dynamic>>.from(gastosData),
          false,
        );
        _cargando = false;
        _errorCarga = null;
      });
    } catch (e) {
      debugPrint('Error cargando cartera de deudas: $e');
      if (!mounted) return;
      setState(() {
        _cargando = false;
        _errorCarga = ErrorMapper.map(e);
      });
    }
  }

  List<Map<String, dynamic>> _agruparDatos(
    List<Map<String, dynamic>> listaCruda,
    bool esCobro,
  ) {
    final grupos = <int, Map<String, dynamic>>{};

    for (final item in listaCruda) {
      final actor = esCobro ? item['clientes'] : item['proveedores'];
      if (actor == null) continue;

      final int idActor = esCobro ? item['cliente_id'] : item['proveedor_id'];
      final String nombre = actor['nombre'] ?? 'Sin Nombre';
      final double saldo = (item['saldo'] as num).toDouble();

      if (!grupos.containsKey(idActor)) {
        grupos[idActor] = {
          'id_actor': idActor,
          'nombre': nombre,
          'total_deuda': 0.0,
          'cantidad_notas': 0,
          'items': <Map<String, dynamic>>[],
        };
      }

      grupos[idActor]!['total_deuda'] += saldo;
      grupos[idActor]!['cantidad_notas'] += 1;
      (grupos[idActor]!['items'] as List).add(item);
    }

    return grupos.values.toList();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        title: const Text(
          'Cartera de Deudas',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        backgroundColor: AppColors.deudas,
        iconTheme: const IconThemeData(color: Colors.white),
        elevation: 0,
      ),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 15, horizontal: 20),
            color: AppColors.deudas,
            child: Container(
              height: 45,
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(25),
              ),
              child: TabBar(
                controller: _tabController,
                indicator: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(22),
                ),
                labelColor: Colors.black,
                unselectedLabelColor: Colors.white,
                labelStyle: const TextStyle(fontWeight: FontWeight.bold),
                dividerColor: Colors.transparent,
                tabs: const [
                  Tab(text: 'POR COBRAR'),
                  Tab(text: 'POR PAGAR'),
                ],
              ),
            ),
          ),
          Expanded(child: _buildContenido()),
        ],
      ),
    );
  }

  Widget _buildContenido() {
    if (_cargando) {
      return Center(child: CircularProgressIndicator(color: colorVerde));
    }

    final error = _errorCarga;
    if (error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.cloud_off_outlined, size: 54, color: Colors.grey[500]),
              const SizedBox(height: 16),
              const Text(
                'No se pudo cargar la cartera',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Text(
                error,
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey[600]),
              ),
              const SizedBox(height: 18),
              FilledButton.icon(
                onPressed: _cargarTodo,
                icon: const Icon(Icons.refresh),
                label: const Text('Reintentar'),
              ),
            ],
          ),
        ),
      );
    }

    return TabBarView(
      controller: _tabController,
      children: [
        _buildListaGrupos(_gruposPorCobrar, true),
        _buildListaGrupos(_gruposPorPagar, false),
      ],
    );
  }

  Widget _buildListaGrupos(List<Map<String, dynamic>> grupos, bool esCobro) {
    if (grupos.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              esCobro
                  ? Icons.check_circle_outline
                  : Icons.sentiment_satisfied_alt,
              size: 80,
              color: Colors.grey[300],
            ),
            const SizedBox(height: 15),
            Text(
              esCobro ? 'Nadie te debe nada' : 'No tienes deudas',
              style: TextStyle(
                color: Colors.grey[600],
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      );
    }

    final colorTema = esCobro ? colorVerde : colorRojo;

    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: grupos.length,
      itemBuilder: (ctx, i) {
        final grupo = grupos[i];

        return Container(
          margin: const EdgeInsets.only(bottom: 12),
          decoration: BoxDecoration(
            color: Theme.of(context).cardColor,
            borderRadius: BorderRadius.circular(15),
            boxShadow: Theme.of(context).brightness == Brightness.dark
                ? []
                : [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.05),
                      blurRadius: 10,
                      offset: const Offset(0, 4),
                    ),
                  ],
          ),
          child: ListTile(
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 20,
              vertical: 12,
            ),
            onTap: () async {
              await Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => DetalleDeudasActorPage(
                    nombreActor: grupo['nombre'],
                    items: grupo['items'],
                    esCobro: esCobro,
                    actorId: grupo['id_actor'],
                  ),
                ),
              );
              if (mounted) await _cargarTodo();
            },
            leading: CircleAvatar(
              backgroundColor: colorTema.withValues(alpha: 0.1),
              radius: 25,
              child: Text(
                grupo['nombre'][0].toUpperCase(),
                style: TextStyle(
                  color: colorTema,
                  fontWeight: FontWeight.bold,
                  fontSize: 20,
                ),
              ),
            ),
            title: Text(
              grupo['nombre'],
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 16,
                color: Theme.of(context).brightness == Brightness.dark
                    ? Colors.white
                    : Colors.black87,
              ),
            ),
            subtitle: Text(
              "${grupo['cantidad_notas']} deudas pendientes",
              style: TextStyle(color: Colors.grey[600]),
            ),
            trailing: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                const Text(
                  'Total',
                  style: TextStyle(fontSize: 10, color: Colors.grey),
                ),
                Text(
                  AppFormatters.currency((grupo['total_deuda'] as double)),
                  style: TextStyle(
                    color: colorTema,
                    fontWeight: FontWeight.w900,
                    fontSize: 16,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
