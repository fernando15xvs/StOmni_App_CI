import 'package:core_logic/core_logic.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

/// Checks automatically once the authorized home interface appears.
/// Opening a private release requires a GitHub account with repository access;
/// installation itself is always explicit (no silent APK/EXE execution).
class QaUpdateNotice extends StatefulWidget {
  const QaUpdateNotice({super.key, required this.platform});

  final QaUpdatePlatform platform;

  @override
  State<QaUpdateNotice> createState() => _QaUpdateNoticeState();
}

class _QaUpdateNoticeState extends State<QaUpdateNotice> {
  QaReleaseAnnouncement? _available;
  bool _dismissed = false;

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    try {
      final info = await PackageInfo.fromPlatform();
      final installedBuild = int.tryParse(info.buildNumber);
      if (installedBuild == null) return;
      final update = await QaUpdateChecker().check(
        platform: widget.platform,
        installedBuild: installedBuild,
      );
      if (mounted) setState(() => _available = update);
    } on Object {
      // Optional notification: do not change login or offline behavior.
    }
  }

  Future<void> _open() async {
    final update = _available;
    if (update == null) return;
    try {
      final opened = await launchUrl(
        update.releaseUri,
        mode: LaunchMode.externalApplication,
      );
      if (opened || !mounted) return;
    } on Object {
      if (!mounted) return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('No se pudo abrir GitHub. Comprueba tu navegador.'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final update = _available;
    if (_dismissed || update == null) return const SizedBox.shrink();
    final kind = widget.platform == QaUpdatePlatform.android
        ? 'Android'
        : 'Windows';
    return MaterialBanner(
      leading: const Icon(Icons.system_update_alt_outlined),
      content: Text(
        'StOmni $kind: nueva versión ${update.version} '
        '(compilación ${update.buildNumber}). '
        'Descárgala desde el repositorio privado de GitHub.',
      ),
      actions: [
        TextButton(
          onPressed: () => setState(() => _dismissed = true),
          child: const Text('Después'),
        ),
        TextButton(onPressed: _open, child: const Text('Ver actualización')),
      ],
    );
  }
}
