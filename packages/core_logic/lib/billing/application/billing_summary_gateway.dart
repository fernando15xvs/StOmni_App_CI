import '../domain/billing_summary.dart';

abstract interface class BillingSummaryGateway {
  Future<BillingSummary> getCurrentSummary();
}
