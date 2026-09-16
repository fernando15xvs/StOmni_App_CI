class DashboardSummary {
  const DashboardSummary({
    required this.ventasHoy,
    required this.gastosHoy,
    required this.totalProductos,
    required this.lowStockCount,
    required this.outOfStockCount,
    required this.deudasPorCobrar,
    required this.deudasPorPagar,
  });

  final double ventasHoy;
  final double gastosHoy;
  final int totalProductos;
  final int lowStockCount;
  final int outOfStockCount;
  final double deudasPorCobrar;
  final double deudasPorPagar;

  double get resultadoOperativoHoy => ventasHoy - gastosHoy;

  int get alertasInventario => lowStockCount + outOfStockCount;

  factory DashboardSummary.fromMap(Map<String, dynamic> map) {
    return DashboardSummary(
      ventasHoy: (map['ventas_hoy'] as num?)?.toDouble() ?? 0.0,
      gastosHoy: (map['gastos_hoy'] as num?)?.toDouble() ?? 0.0,
      totalProductos: (map['total_productos'] as num?)?.toInt() ?? 0,
      lowStockCount: (map['low_stock_count'] as num?)?.toInt() ?? 0,
      outOfStockCount: (map['out_of_stock_count'] as num?)?.toInt() ?? 0,
      deudasPorCobrar: (map['deudas_por_cobrar'] as num?)?.toDouble() ?? 0.0,
      deudasPorPagar: (map['deudas_por_pagar'] as num?)?.toDouble() ?? 0.0,
    );
  }

  Map<String, dynamic> toMap() => {
    'ventas_hoy': ventasHoy,
    'gastos_hoy': gastosHoy,
    'total_productos': totalProductos,
    'low_stock_count': lowStockCount,
    'out_of_stock_count': outOfStockCount,
    'deudas_por_cobrar': deudasPorCobrar,
    'deudas_por_pagar': deudasPorPagar,
  };
}
