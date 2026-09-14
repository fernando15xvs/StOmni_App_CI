import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/supabase_provider.dart';
import '../application/audit_log_gateway.dart';
import '../data/supabase_audit_log_gateway.dart';

final auditLogGatewayProvider = Provider<AuditLogGateway>(
  (ref) => SupabaseAuditLogGateway(ref.watch(supabaseProvider)),
);
