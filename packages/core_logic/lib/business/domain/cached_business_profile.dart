import 'business_profile.dart';

/// Snapshot operativo, no sustituye autorización ni las restricciones del servidor.
class CachedBusinessProfile {
  const CachedBusinessProfile({required this.profile, required this.cachedAt});
  final BusinessProfile profile;
  final DateTime cachedAt;

  bool isCurrentAt(DateTime now) =>
      !cachedAt.isAfter(now.add(const Duration(minutes: 5))) &&
      cachedAt.add(const Duration(hours: 24)).isAfter(now);
}
