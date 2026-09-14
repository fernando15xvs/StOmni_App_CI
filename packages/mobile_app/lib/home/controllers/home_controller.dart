import 'package:flutter_riverpod/flutter_riverpod.dart';

// Pestaña actual del Home.
final homeTabProvider = StateProvider<int>((ref) => 0);

/// Revisión global para invalidaciones explícitas del Home.
///
/// Sustituye el `ValueNotifier` global legado y permite que cualquier Ref de
/// Riverpod solicite un refresh sin mezclar dos mecanismos de estado.
final homeRefreshRevisionProvider = StateProvider<int>((ref) => 0);