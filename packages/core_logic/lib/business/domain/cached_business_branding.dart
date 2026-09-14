import 'business_branding.dart';

/// Snapshot visual local. No concede autorización ni selecciona un tenant.
class CachedBusinessBranding {
  const CachedBusinessBranding({
    required this.branding,
    required this.cachedAt,
  });

  static const ttl = Duration(hours: 24);
  static const maxFutureClockSkew = Duration(minutes: 5);

  final BusinessBranding branding;
  final DateTime cachedAt;

  bool isCurrentAt(DateTime now) {
    final timestamp = cachedAt.toUtc();
    final instant = now.toUtc();
    return !timestamp.isAfter(instant.add(maxFutureClockSkew)) &&
        timestamp.add(ttl).isAfter(instant);
  }
}
