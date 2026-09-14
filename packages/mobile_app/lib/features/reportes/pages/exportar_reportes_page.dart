import 'package:mobile_app/platform/documents/mobile_document_output.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_app/core/theme/app_colors.dart';

import 'package:core_logic/core_logic.dart';

class ExportarReportesPage extends ConsumerStatefulWidget {
  final DateTime fechaInicio;
  final DateTime fechaFin;

  const ExportarReportesPage({
    super.key,
    required this.fechaInicio,
    required this.fechaFin,
  });

  @override
  ConsumerState<ExportarReportesPage> createState() =>
      _ExportarReportesPageState();
}

class _ExportarReportesPageState extends ConsumerState<ExportarReportesPage> {
  bool _ventas = false;
  bool _abonos = false;
  bool _gastos = false;
  bool _personal = false;

  bool _descargando = false;

  final Color colorTexto = const Color(0xFF1F2937);
  final Color colorReportes = AppColors.reportes;

  Future<void> _procesarDescarga() async {
    if (_descargando) return;
    if (!_ventas && !_abonos && !_gastos && !_personal) return;

    setState(() => _descargando = true);

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) =>
          const Center(child: CircularProgressIndicator(color: Colors.white)),
    );

    try {
      final snapshot = await ref.read(reportesExportRepositoryProvider).cargarExcel(
            fechaInicio: widget.fechaInicio,
            fechaFin: widget.fechaFin,
            incluirVentas: _ventas,
            incluirAbonos: _abonos,
            incluirGastos: _gastos,
            incluirPersonal: _personal,
          );

      final document = await ReporteExcelService.generar(
        fechaInicio: widget.fechaInicio,
        fechaFin: widget.fechaFin,
        snapshot: snapshot,
        incluirVentas: _ventas,
        incluirAbonos: _abonos,
        incluirGastos: _gastos,
        incluirPersonal: _personal,
      );
      if (!mounted) return;
      final resultado = await documentOutputFor(context).deliver(document);

      if (!mounted) return;
      Navigator.pop(context);

      if (resultado == DocumentOutputResult.saved) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Excel guardado correctamente en tu PC.'),
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
    final haySeleccion = _ventas || _abonos || _gastos || _personal;

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        backgroundColor: colorReportes,
        iconTheme: const IconThemeData(color: Colors.white),
        title: const Text(
          'Reporte Financiero',
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
              'Reporte Financiero',
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.w900,
                letterSpacing: -0.5,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              'Selecciona los reportes financieros que deseas descargar. Se generará un único archivo Excel con pestañas independientes por cada opción marcada.',
              style: TextStyle(
                fontSize: 14,
                color: Theme.of(context).brightness == Brightness.dark
                    ? Colors.grey[400]
                    : Colors.grey[600],
                height: 1.4,
              ),
            ),
            const SizedBox(height: 30),
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
                    title: 'Ventas realizadas',
                    value: _ventas,
                    onChanged: (v) => setState(() => _ventas = v ?? false),
                  ),
                  const Divider(height: 1, indent: 20, endIndent: 20),
                  _buildCheckOption(
                    title: 'Cobros / Abonos de ventas a crédito',
                    value: _abonos,
                    onChanged: (v) => setState(() => _abonos = v ?? false),
                  ),
                  const Divider(height: 1, indent: 20, endIndent: 20),
                  _buildCheckOption(
                    title: 'Reporte de Egresos (Gastos Operativos)',
                    value: _gastos,
                    onChanged: (v) => setState(() => _gastos = v ?? false),
                  ),
                  const Divider(height: 1, indent: 20, endIndent: 20),
                  _buildCheckOption(
                    title: 'Reporte de Egresos (Pagos a Personal)',
                    value: _personal,
                    onChanged: (v) => setState(() => _personal = v ?? false),
                  ),
                ],
              ),
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
                Icons.download_rounded,
                color: haySeleccion ? Colors.white : Colors.grey[500],
              ),
              label: Text(
                _descargando ? 'PROCESANDO...' : 'DESCARGAR SELECCIONADOS',
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
              child: Text(
                title,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                  color: Theme.of(context).brightness == Brightness.dark
                      ? Colors.white
                      : colorTexto,
                ),
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
