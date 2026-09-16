import 'package:core_logic/core_logic.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final supplierUseCaseProvider = Provider<SupplierUseCase>((ref) {
  return SupplierUseCase(SupabaseSupplierGateway(ref.read(supabaseProvider)));
});
