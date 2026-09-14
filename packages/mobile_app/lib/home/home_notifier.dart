/// Bridge temporal para callers antiguos que todavía ejecutan
/// `homeRefreshNotifier.value++` o registran listeners.
///
/// Ya no almacena estado observable ni usa `ValueNotifier`: el trigger se
/// conecta desde `HomePage` al `homeRefreshRevisionProvider` de Riverpod y los
/// listeners legados reciben la notificación desde el cambio de ese provider.
class HomeRefreshCompatibilityBridge {
  void Function()? _onTrigger;
  final Set<void Function()> _legacyListeners = <void Function()>{};
  int _compatValue = 0;

  int get value => _compatValue;

  set value(int next) {
    _compatValue = next;
    _onTrigger?.call();
  }

  void attach(void Function() onTrigger) {
    _onTrigger = onTrigger;
  }

  void detach(void Function() onTrigger) {
    if (identical(_onTrigger, onTrigger)) {
      _onTrigger = null;
    }
  }

  void addListener(void Function() listener) {
    _legacyListeners.add(listener);
  }

  void removeListener(void Function() listener) {
    _legacyListeners.remove(listener);
  }

  void notifyLegacyListeners() {
    for (final listener in List<void Function()>.from(_legacyListeners)) {
      listener();
    }
  }

  void trigger() {
    value = _compatValue + 1;
  }
}

// Compatibilidad transitoria para pantallas aún no migradas. No se marca como
// deprecated para no contaminar el analyzer mientras Riverpod ya es la fuente
// de verdad del refresh global.
final homeRefreshNotifier = HomeRefreshCompatibilityBridge();

void triggerHomeRefresh() => homeRefreshNotifier.trigger();
