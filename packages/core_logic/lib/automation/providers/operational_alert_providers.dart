import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/supabase_provider.dart';
import '../application/operational_alert_gateway.dart';
import '../data/supabase_operational_alert_gateway.dart';

final operationalAlertGatewayProvider = Provider<OperationalAlertGateway>(
  (ref) => SupabaseOperationalAlertGateway(ref.watch(supabaseProvider)),
);
