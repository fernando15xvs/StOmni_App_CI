/// Snapshot documental independiente del repositorio que lo carga.
class ReportesExcelSnapshot {
  const ReportesExcelSnapshot({
    this.almacenes = const <int, String>{},
    this.ventas = const [],
    this.detallesVentas = const [],
    this.pagosCredito = const [],
    this.detallesAbonos = const [],
    this.pagosGasto = const [],
    this.pagosPersonal = const [],
  });

  final Map<int, String> almacenes;
  final List<Map<String, dynamic>> ventas;
  final List<Map<String, dynamic>> detallesVentas;
  final List<Map<String, dynamic>> pagosCredito;
  final List<Map<String, dynamic>> detallesAbonos;
  final List<Map<String, dynamic>> pagosGasto;
  final List<Map<String, dynamic>> pagosPersonal;
}
