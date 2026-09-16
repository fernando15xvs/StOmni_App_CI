import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../home/controllers/home_controller.dart';
import '../home/home_notifier.dart';

/// Adaptador temporal de salida para pantallas antiguas que aún registran un
/// listener de refresh. La fuente de verdad es Riverpod; el bridge no contiene
/// un ValueNotifier ni decide cuándo refrescar.
class HomeRefreshSync extends ConsumerWidget {
  const HomeRefreshSync({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.listen<int>(homeRefreshRevisionProvider, (previous, next) {
      if (previous == next) return;
      homeRefreshNotifier.notifyLegacyListeners();
    });
    return child;
  }
}
