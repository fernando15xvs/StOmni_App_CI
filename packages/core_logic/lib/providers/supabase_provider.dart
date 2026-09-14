import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Cliente Supabase compartido por todas las features.
///
/// Mantener este provider en `core` evita que una feature tenga que importar
/// otra feature solo para obtener acceso al cliente de Supabase.
final supabaseProvider = Provider<SupabaseClient>((ref) {
  return Supabase.instance.client;
});
