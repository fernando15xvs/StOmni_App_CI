import 'package:mobile_app/platform/documents/mobile_document_output.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:mobile_app/core/theme/app_colors.dart';

import 'package:core_logic/core_logic.dart';

class ExportarInventarioPdfPage extends ConsumerStatefulWidget {
  final DateTime fechaInicio;
  final DateTime fechaFin;

  const ExportarInventarioPdfPage({
    super.key,
    required this.fechaInicio,
    required this.fechaFin,
  });

  @override
  ConsumerState<ExportarInventarioPdfPage> createState() =>
      _ExportarInventarioPdfPageState();
}

class _ExportarInventarioPdfPageState
    extends ConsumerState<ExportarInventarioPdfPage> {
  bool _ingresos = true;
  bool _salidas = true;
  bool _traslados = true;
  bool _descargando = false;

  final Color colorTexto = const Color(0xFF1F2937);
  final Color colorReportes = AppColors.reportes;

  Future<void> _procesarDescarga() async {
    if (_descargando) return;
    if (!_ingresos && !_salidas && !_traslados) return;

    setState(() => _descargando = true);

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) =>
          const Center(child: CircularProgressIndicator(color: Colors.white)),
    );

    try {
      final movimientos = await ref
          .read(reportesExportRepositoryProvider)
          .cargarMovimientosInventario(
            fechaInicio: widget.fechaInicio,
            fechaFin: widget.fechaFin,
          );

      final document = await InventarioPdfService.generar(
        fechaInicio: widget.fechaInicio,
        fechaFin: widget.fechaFin,
        movimientos: movimientos,
        incluirIngresos: _ingresos,
        incluirSalidas: _salidas,
        incluirTraslados: _traslados,
      );
      if (!mounted) return;
      final resultado = await documentOutputFor(context).deliver(document);

      if (!mounted) return;
      Navigator.pop(context);

      if (resultado == DocumentOutputResult.saved) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('PDF guardado correctamente en tu PC.'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(ErrorMapper.map(e)),
          backgroundColor: Colors.red,
        ),
      );
    } finally {
      if (mounted) setState(() => _descargando = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final haySeleccion = _ingresos || _salidas || _traslados;

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        backgroundColor: colorReportes,
        iconTheme: const IconThemeData(color: Colors.white),
        title: const Text(
          'Reporte Inventario',
          style: TextStyle(
            color: Colors.white,
            fontSize: 18,
            fontWeight: FontWeight.w800,
          ),
        ),
        centerTitle: true,
        elevation: 0,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Reporte Inventario',
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.w900,
                letterSpacing: -0.5,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              'Selecciona uno o varios tipos. Si marcas más de uno, se generará un único PDF con secciones separadas.',
              style: TextStyle(
                fontSize: 14,
                color: Theme.of(context).brightness == Brightness.dark
                    ? Colors.grey[400]
                    : Colors.grey[600],
                height: 1.4,
              ),
            ),
            const SizedBox(height: 28),
            Container(
              decoration: BoxDecoration(
                color: Theme.of(context).cardColor,
                borderRadius: BorderRadius.circular(20),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.03),
                    blurRadius: 15,
                    offset: const Offset(0, 5),
                  ),
                ],
              ),
              child: Column(
                children: [
                  _buildCheckOption(
                    title: 'Ingresos',
                    subtitle: 'Entradas, compras y ajustes positivos',
                    value: _ingresos,
                    onChanged: (v) => setState(() => _ingresos = v ?? false),
                  ),
                  const Divider(height: 1, indent: 20, endIndent: 20),
                  _buildCheckOption(
                    title: 'Salidas',
                    subtitle: 'Ventas, ajustes negativos y devoluciones',
                    value: _salidas,
                    onChanged: (v) => setState(() => _salidas = v ?? false),
                  ),
                  const Divider(height: 1, indent: 20, endIndent: 20),
                  _buildCheckOption(
                    title: 'Traslados',
                    subtitle: 'Movimientos entre almacenes',
                    value: _traslados,
                    onChanged: (v) => setState(() => _traslados = v ?? false),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),
            Row(
              children: [
                TextButton.icon(
                  onPressed: _descargando
                      ? null
                      : () => setState(() {
                          _ingresos = true;
                          _salidas = true;
                          _traslados = true;
                        }),
                  icon: const Icon(Icons.select_all),
                  label: const Text('Seleccionar todo'),
                ),
                const SizedBox(width: 8),
                TextButton.icon(
                  onPressed: _descargando
                      ? null
                      : () => setState(() {
                          _ingresos = false;
                          _salidas = false;
                          _traslados = false;
                        }),
                  icon: const Icon(Icons.remove_done),
                  label: const Text('Limpiar'),
                ),
              ],
            ),
          ],
        ),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20.0),
          child: SizedBox(
            height: 55,
            child: ElevatedButton.icon(
              onPressed: (haySeleccion && !_descargando)
                  ? _procesarDescarga
                  : null,
              style: ElevatedButton.styleFrom(
                backgroundColor: colorReportes,
                disabledBackgroundColor:
                    Theme.of(context).brightness == Brightness.dark
                    ? Colors.grey[800]
                    : Colors.grey[300],
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                elevation: (haySeleccion && !_descargando) ? 5 : 0,
              ),
              icon: Icon(
                Icons.picture_as_pdf_rounded,
                color: haySeleccion ? Colors.white : Colors.grey[500],
              ),
              label: Text(
                _descargando ? 'PROCESANDO...' : 'DESCARGAR PDF',
                style: TextStyle(
                  color: haySeleccion ? Colors.white : Colors.grey[500],
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.5,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCheckOption({
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool?> onChanged,
  }) {
    return InkWell(
      onTap: _descargando ? null : () => onChanged(!value),
      borderRadius: BorderRadius.circular(20),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                      color: Theme.of(context).brightness == Brightness.dark
                          ? Colors.white
                          : colorTexto,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).brightness == Brightness.dark
                          ? Colors.grey[400]
                          : Colors.grey[600],
                    ),
                  ),
                ],
              ),
            ),
            SizedBox(
              width: 24,
              height: 24,
              child: Checkbox(
                value: value,
                onChanged: _descargando ? null : onChanged,
                activeColor: colorReportes,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
