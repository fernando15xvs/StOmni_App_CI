import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/supabase_provider.dart';
import '../application/custom_field_gateway.dart';
import '../data/supabase_custom_field_gateway.dart';

final customFieldGatewayProvider = Provider<CustomFieldGateway>((ref) {
  return SupabaseCustomFieldGateway(ref.read(supabaseProvider));
});