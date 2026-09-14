import '../../../auth/application/operation_authorizer.dart';
import '../../../auth/domain/app_permission.dart';
import '../../../errors/user_facing_exception.dart';
import 'business_assistant_gateway.dart';
import '../domain/business_assistant.dart';

class BusinessAssistantUseCase {
  const BusinessAssistantUseCase({
    required BusinessAssistantGateway gateway,
    required OperationAuthorizer authorizer,
  }) : _gateway = gateway,
       _authorizer = authorizer;

  final BusinessAssistantGateway _gateway;
  final OperationAuthorizer _authorizer;

  Future<BusinessAssistantSettings> settings() async {
    await _authorizer.require({AppPermission.reportsViewProfit});
    return _gateway.getSettings();
  }

  Future<BusinessAssistantSettings> updateSettings({
    required int expectedRevision,
    required bool enabled,
    required int maxResultItems,
    required int defaultPeriodDays,
  }) async {
    final user = await _authorizer.require({AppPermission.businessConfigure});
    if (maxResultItems < 1 || maxResultItems > 50 ||
        defaultPeriodDays < 1 || defaultPeriodDays > 365) {
      throw const UserFacingException('La configuración del asistente es inválida.');
    }
    final saved = await _gateway.updateSettings(
      expectedRevision: expectedRevision,
      enabled: enabled,
      maxResultItems: maxResultItems,
      defaultPeriodDays: defaultPeriodDays,
    );
    if (_authorizer.currentAuthUserId != user) {
      throw const UserFacingException('La sesión cambió mientras se configuraba el asistente.');
    }
    return saved;
  }

  Future<BusinessAssistantContext> ask({
    required BusinessAssistantIntent intent,
    int? periodDays,
    String? branchId,
    int? limit,
  }) async {
    final user = await _authorizer.require({AppPermission.reportsViewProfit});
    if (periodDays != null && (periodDays < 1 || periodDays > 365)) {
      throw const UserFacingException('El periodo del asistente debe estar entre 1 y 365 días.');
    }
    if (limit != null && (limit < 1 || limit > 50)) {
      throw const UserFacingException('El límite de resultados del asistente es inválido.');
    }
    final result = await _gateway.loadContext(
      intent: intent,
      periodDays: periodDays,
      branchId: branchId,
      limit: limit,
    );
    if (_authorizer.currentAuthUserId != user) {
      throw const UserFacingException('La sesión cambió mientras se consultaba el asistente.');
    }
    return result;
  }
}
