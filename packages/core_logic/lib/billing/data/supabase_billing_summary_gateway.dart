import 'package:supabase_flutter/supabase_flutter.dart';

import '../application/billing_summary_gateway.dart';
import '../domain/billing_summary.dart';

class SupabaseBillingSummaryGateway implements BillingSummaryGateway {
  const SupabaseBillingSummaryGateway(this.client);
  final SupabaseClient client;

  @override
  Future<BillingSummary> getCurrentSummary() async {
    final raw=await client.rpc('get_my_billing_summary_v1');
    if(raw is! Map) throw const FormatException('El resumen de facturación es inválido.');
    return BillingSummary.fromJson(Map<String,dynamic>.from(raw));
  }
}
