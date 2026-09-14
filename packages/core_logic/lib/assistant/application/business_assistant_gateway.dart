import '../domain/business_assistant.dart';

abstract interface class BusinessAssistantGateway {
  Future<BusinessAssistantSettings> getSettings();

  Future<BusinessAssistantSettings> updateSettings({
    required int expectedRevision,
    required bool enabled,
    required int maxResultItems,
    required int defaultPeriodDays,
  });

  Future<BusinessAssistantContext> loadContext({
    required BusinessAssistantIntent intent,
    int? periodDays,
    String? branchId,
    int? limit,
  });
}
