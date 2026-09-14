import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/supabase_provider.dart';
import '../application/billing_summary_gateway.dart';
import '../data/supabase_billing_summary_gateway.dart';
import '../domain/billing_summary.dart';

final billingSummaryGatewayProvider=Provider<BillingSummaryGateway>(
  (ref)=>SupabaseBillingSummaryGateway(ref.watch(supabaseProvider)),
);

final currentBillingSummaryProvider=FutureProvider<BillingSummary>(
  (ref)=>ref.watch(billingSummaryGatewayProvider).getCurrentSummary(),
);
