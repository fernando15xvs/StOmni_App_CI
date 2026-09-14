import 'package:flutter/material.dart';
import 'historial_caja_page.dart';
import 'package:core_logic/core_logic.dart';
import '../../../core/widgets/app_form_styles.dart';
import '../widgets/balance_widgets.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

class CajaChicaPage extends ConsumerStatefulWidget {
  const CajaChicaPage({super.key});

  @override
  ConsumerState<CajaChicaPage> createState() => _CajaChicaPageState();
}

class _CajaChicaPageState extends ConsumerState<CajaChicaPage> {
  Color get colorVerde => Theme.of(context).colorScheme.primary;
  bool _cargando = true;
  String? _errorCarga;
  Map<String, dynamic>? _estadoCaja;
  List<Map<String, dynamic>> _movimientos = [];

  @override
  void initState() {
    super.initState();
    _cargarEstado();
  }

  Future<void> _cargarEstado() async {
    if (mounted) {
      setState(() {
        _cargando = true;
        _errorCarga = null;
      });
    }
    try {
      final repo = ref.read(balanceRepositoryProvider);
      final res = await repo.getEstadoCajaChica();
      List<Map<String, dynamic>> movs = [];

      if (res != null && res['estado'] == 'ABIERTA') {
        final fechaApertura = res['sesion']['fecha_apertura'];
        movs = await repo.getMovimientosCajaAbierta(fechaApertura);
      }

      if (mounted) {
        setState(() {
          _estadoCaja = res;
          _movimientos = movs;
          _errorCarga = null;
          _cargando = false;
        });
      }
    } catch (e, st) {
      debugPrint('CajaChicaPage: fallo al cargar estado: $e');
      debugPrintStack(stackTrace: st);
      if (mounted) {
        setState(() {
          _errorCarga = ErrorMapper.map(e);
          _cargando = false;
        });
      }
    }
  }

  Future<void> _abrirCaja() async {
    final montoCtrl = TextEditingController();
    bool formCargando = false;

    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setStateDialog) {
          return AlertDialog(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
            ),
            title: const Text(
              "Abrir Caja",
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text("Ingresa el monto de efectivo inicial (sencillo)."),
                const SizedBox(height: 15),
                TextField(
                  controller: montoCtrl,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: AppFormStyles.inputDecor(
                    context,
                    "Monto Inicial (S/)",
                    icon: Icons.attach_money,
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: formCargando ? null : () => Navigator.pop(ctx),
                child: const Text(
                  "Cancelar",
                  style: TextStyle(color: Colors.grey),
                ),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: colorVerde,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                onPressed: formCargando
                    ? null
                    : () async {
                        final monto = double.tryParse(montoCtrl.text);
                        if (monto == null || monto < 0) return;

                        setStateDialog(() => formCargando = true);
                        try {
                          final repo = ref.read(balanceRepositoryProvider);
                          await repo.abrirCaja(monto);
                          if (ctx.mounted) {
                            Navigator.pop(ctx);
                          }
                          await _cargarEstado();
                        } catch (e) {
                          setStateDialog(() => formCargando = false);
                          if (ctx.mounted) {
                            ScaffoldMessenger.of(ctx).showSnackBar(
                              SnackBar(
                                content: Text(
                                  ErrorMapper.map(e),
                                  style: const TextStyle(color: Colors.white),
                                ),
                                backgroundColor: Colors.red,
                              ),
                            );
                          }
                        }
                      },
                child: formCargando
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          color: Colors.white,
                          strokeWidth: 2,
                        ),
                      )
                    : const Text(
                        "Abrir Turno",
                        style: TextStyle(color: Colors.white),
                      ),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _cerrarCaja(double esperado) async {
    final montoCtrl = TextEditingController();
    final obsCtrl = TextEditingController();
    bool formCargando = false;
    double? montoRealInput;
    String errorObs = '';

    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setStateDialog) {
          final tieneDiferencia =
              montoRealInput != null &&
              (montoRealInput! - esperado).abs() > 0.01;

          return AlertDialog(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
            ),
            title: const Text(
              "Cerrar Caja",
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    "Ingresa el monto de efectivo REAL que hay en tu gaveta ahora mismo.",
                  ),
                  const SizedBox(height: 15),
                  TextField(
                    controller: montoCtrl,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: AppFormStyles.inputDecor(
                      context,
                      "Monto Real (S/)",
                      icon: Icons.payments_rounded,
                    ),
                    onChanged: (val) {
                      setStateDialog(() {
                        montoRealInput = double.tryParse(val);
                        errorObs = '';
                      });
                    },
                  ),
                  if (tieneDiferencia) ...[
                    const SizedBox(height: 20),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.orange.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: Colors.orange.withValues(alpha: 0.5),
                        ),
                      ),
                      child: Column(
                        children: [
                          Row(
                            children: [
                              const Icon(
                                Icons.warning_amber_rounded,
                                color: Colors.orange,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  montoRealInput! > esperado
                                      ? "Hay un SOBRANTE de ${AppFormatters.currency((montoRealInput! - esperado))}"
                                      : "Hay un FALTANTE de ${AppFormatters.currency((esperado - montoRealInput!))}",
                                  style: const TextStyle(
                                    color: Colors.orange,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          TextField(
                            controller: obsCtrl,
                            maxLines: 2,
                            decoration:
                                AppFormStyles.inputDecor(
                                  context,
                                  "Motivo / Observación (Obligatorio)",
                                  icon: Icons.description,
                                ).copyWith(
                                  errorText: errorObs.isNotEmpty
                                      ? errorObs
                                      : null,
                                ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: formCargando ? null : () => Navigator.pop(ctx),
                child: const Text(
                  "Cancelar",
                  style: TextStyle(color: Colors.grey),
                ),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.redAccent,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                onPressed: formCargando
                    ? null
                    : () async {
                        final montoReal = double.tryParse(montoCtrl.text);
                        if (montoReal == null || montoReal < 0) return;

                        if (tieneDiferencia && obsCtrl.text.trim().isEmpty) {
                          setStateDialog(
                            () => errorObs = "Debes justificar la diferencia.",
                          );
                          return;
                        }

                        setStateDialog(() => formCargando = true);
                        try {
                          final sesionId = _estadoCaja!['sesion']['id'];
                          final fechaApertura =
                              _estadoCaja!['sesion']['fecha_apertura'];
                          final montoApertura =
                              _estadoCaja!['sesion']['monto_apertura']
                                  .toDouble();

                          final repo = ref.read(balanceRepositoryProvider);
                          await repo.cerrarCaja(
                            sesionId: sesionId,
                            fechaApertura: fechaApertura,
                            montoApertura: montoApertura,
                            esperado: esperado,
                            real: montoReal,
                            observaciones: tieneDiferencia
                                ? obsCtrl.text.trim()
                                : null,
                          );

                          if (ctx.mounted) {
                            Navigator.pop(ctx);
                          }

                          final diff = montoReal - esperado;
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                  diff == 0
                                      ? "¡Caja cerrada con Cuadre Perfecto! ✅"
                                      : diff > 0
                                      ? "Caja cerrada con Sobrante de ${AppFormatters.currency(diff)}"
                                      : "Caja cerrada con Faltante de ${AppFormatters.currency(diff.abs())}",
                                ),
                                backgroundColor: diff == 0
                                    ? colorVerde
                                    : (diff > 0 ? Colors.blue : Colors.red),
                                duration: const Duration(seconds: 5),
                              ),
                            );
                          }
                          await _cargarEstado();
                        } catch (e) {
                          setStateDialog(() => formCargando = false);
                          if (ctx.mounted) {
                            ScaffoldMessenger.of(ctx).showSnackBar(
                              SnackBar(
                                content: Text(
                                  ErrorMapper.map(e),
                                  style: const TextStyle(color: Colors.white),
                                ),
                                backgroundColor: Colors.red,
                              ),
                            );
                          }
                        }
                      },
                child: formCargando
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          color: Colors.white,
                          strokeWidth: 2,
                        ),
                      )
                    : const Text(
                        "Confirmar Cierre",
                        style: TextStyle(color: Colors.white),
                      ),
              ),
            ],
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    Widget content;

    if (_cargando) {
      content = const Center(child: CircularProgressIndicator());
    } else if (_errorCarga != null) {
      content = Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_off_outlined, size: 52),
              const SizedBox(height: 16),
              Text(
                _errorCarga!,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: _cargarEstado,
                icon: const Icon(Icons.refresh),
                label: const Text('Reintentar'),
              ),
            ],
          ),
        ),
      );
    } else if (_estadoCaja == null || _estadoCaja!['estado'] == 'CERRADA') {
      content = Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.lock_outline_rounded, size: 80, color: Colors.grey[400]),
            const SizedBox(height: 16),
            const Text(
              "Caja Cerrada",
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              "Abre un turno para registrar el flujo de efectivo físico.",
              style: TextStyle(color: Colors.grey[600]),
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: _abrirCaja,
              icon: const Icon(Icons.key, color: Colors.white),
              label: const Text(
                "Abrir Caja Chica",
                style: TextStyle(color: Colors.white),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: colorVerde,
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 12,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ],
        ),
      );
    } else {
      final apertura = (_estadoCaja!['sesion']['monto_apertura'] as num)
          .toDouble();
      final ingresos = (_estadoCaja!['ingresos_efectivo'] as num).toDouble();
      final egresos = (_estadoCaja!['egresos_efectivo'] as num).toDouble();
      final saldoEsperado = (_estadoCaja!['saldo_esperado'] as num).toDouble();

      final fechaIso = _estadoCaja!['sesion']['fecha_apertura'];
      final formatoFecha = AppFormatters.limaDateTimeText(fechaIso);

      content = RefreshIndicator(
        onRefresh: _cargarEstado,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(16),
          children: [
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: Theme.of(context).cardColor,
                borderRadius: BorderRadius.circular(20),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.05),
                    blurRadius: 10,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        "Estado Actual",
                        style: TextStyle(
                          color: Colors.grey,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: colorVerde.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          "ABIERTA",
                          style: TextStyle(
                            color: colorVerde,
                            fontWeight: FontWeight.bold,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 5),
                  Text(
                    "Desde: $formatoFecha",
                    style: const TextStyle(fontSize: 14),
                  ),
                  const Divider(height: 30),

                  _buildRow("Monto Inicial", apertura, Colors.blueGrey),
                  const SizedBox(height: 10),
                  _buildRow("Ingresos en Efectivo (+)", ingresos, colorVerde),
                  const SizedBox(height: 10),
                  _buildRow(
                    "Egresos en Efectivo (-)",
                    egresos,
                    Colors.redAccent,
                  ),

                  const Divider(height: 30),
                  const Text(
                    "Saldo Esperado en Gaveta",
                    style: TextStyle(fontSize: 14, color: Colors.grey),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    AppFormatters.currency(saldoEsperado),
                    style: TextStyle(
                      fontSize: 32,
                      fontWeight: FontWeight.w900,
                      color: colorVerde,
                    ),
                  ),
                  const SizedBox(height: 30),

                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: () => _cerrarCaja(saldoEsperado),
                      icon: const Icon(
                        Icons.lock_outline_rounded,
                        color: Colors.white,
                      ),
                      label: const Text(
                        "Cerrar Turno de Caja",
                        style: TextStyle(color: Colors.white, fontSize: 16),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.redAccent,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            if (_movimientos.isNotEmpty) ...[
              const Text(
                "Últimos Movimientos de Caja",
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 10),
              ..._movimientos.map((m) {
                return ItemMovimientoCaja(movimiento: m);
              }),
            ],
          ],
        ),
      );
    }

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        title: const Text(
          'Caja Chica',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        backgroundColor: colorVerde,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
        actions: [
          IconButton(
            icon: const Icon(Icons.history_rounded),
            tooltip: 'Ver Historial',
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const HistorialCajaPage()),
              );
            },
          ),
        ],
      ),
      body: content,
    );
  }

  Widget _buildRow(String label, double amount, Color color) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: const TextStyle(fontSize: 15)),
        Text(
          AppFormatters.currency(amount),
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.bold,
            color: color,
          ),
        ),
      ],
    );
  }
}
