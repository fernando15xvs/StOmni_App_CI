import 'package:core_logic/core_logic.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final customerUseCaseProvider = Provider<CustomerUseCase>((ref) {
  return CustomerUseCase(SupabaseCustomerGateway(ref.read(supabaseProvider)));
});
