import '../../../auth/application/operation_authorizer.dart';
import '../../../auth/domain/app_permission.dart';
import '../../../errors/user_facing_exception.dart';
import '../domain/configurable_metric.dart';

abstract interface class ConfigurableMetricGateway {
  Future<List<ConfigurableMetricDefinition>> listDefinitions();
  Future<List<ConfigurableMetricDefinition>> saveDefinitions(
    List<ConfigurableMetricDefinition> definitions,
  );
  Future<ConfigurableDashboardSnapshot> loadDashboard({
    required DateTime start,
    required DateTime end,
    String? branchId,
  });
}

class ConfigurableMetricsUseCase {
  const ConfigurableMetricsUseCase({
    required ConfigurableMetricGateway metrics,
    required OperationAuthorizer authorizer,
  }) : _metrics = metrics,
       _authorizer = authorizer;

  final ConfigurableMetricGateway _metrics;
  final OperationAuthorizer _authorizer;

  Future<List<ConfigurableMetricDefinition>> definitions() async {
    await _authorizer.require({AppPermission.reportsViewProfit});
    return _metrics.listDefinitions();
  }

  Future<List<ConfigurableMetricDefinition>> save(
    List<ConfigurableMetricDefinition> definitions,
  ) async {
    final user = await _authorizer.require({AppPermission.businessConfigure});
    _validateDefinitions(definitions);
    final saved = await _metrics.saveDefinitions(definitions);
    if (_authorizer.currentAuthUserId != user) {
      throw const UserFacingException('La sesión cambió mientras se guardaban las métricas.');
    }
    return saved;
  }

  Future<ConfigurableDashboardSnapshot> dashboard({
    required DateTime start,
    required DateTime end,
    String? branchId,
  }) async {
    if (end.isBefore(start) || end.isAtSameMomentAs(start)) {
      throw ArgumentError('El fin del periodo debe ser posterior al inicio.');
    }
    if (end.difference(start) > const Duration(days: 366)) {
      throw ArgumentError('El dashboard admite periodos de hasta 366 días.');
    }
    final user = await _authorizer.require({AppPermission.reportsViewProfit});
    final snapshot = await _metrics.loadDashboard(
      start: start,
      end: end,
      branchId: branchId,
    );
    if (_authorizer.currentAuthUserId != user) {
      throw const UserFacingException('La sesión cambió mientras se calculaba el dashboard.');
    }
    return snapshot;
  }

  Future<List<MetricValue>> evaluate({
    required DateTime start,
    required DateTime end,
    String? branchId,
  }) async {
    final snapshot = await dashboard(start: start, end: end, branchId: branchId);
    return snapshot.metrics;
  }

  void _validateDefinitions(List<ConfigurableMetricDefinition> definitions) {
    if (definitions.length > MetricSource.values.length) {
      throw const UserFacingException('Hay demasiadas métricas configuradas.');
    }
    final sources = <MetricSource>{};
    final positions = <int>{};
    for (final definition in definitions) {
      if (!sources.add(definition.source) ||
          !positions.add(definition.position) ||
          definition.position < 0 ||
          definition.position > 100 ||
          definition.label.trim().isEmpty ||
          definition.label.trim().length > 80) {
        throw const UserFacingException('La configuración de métricas contiene duplicados o datos inválidos.');
      }
    }
  }
}
