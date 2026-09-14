import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Provider que incrementa su valor entero para indicar a
/// ProductSearchWidget que debe volver a consultar a SQLite
/// (por ejemplo, después de una actualización silenciosa de Realtime).
final productSearchRevisionProvider = StateProvider<int>((ref) => 0);
