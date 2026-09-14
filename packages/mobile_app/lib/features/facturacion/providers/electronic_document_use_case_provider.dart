import 'package:core_logic/features/facturacion/application/electronic_document_use_case.dart';
import 'package:core_logic/features/facturacion/data/supabase_electronic_document_gateway.dart';
import 'package:core_logic/providers/supabase_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final electronicDocumentUseCaseProvider = Provider<ElectronicDocumentUseCase>(
  (ref) => ElectronicDocumentUseCase(
    SupabaseElectronicDocumentGateway(ref.read(supabaseProvider)),
  ),
);
