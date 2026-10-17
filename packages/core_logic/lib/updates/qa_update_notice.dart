import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

/// Only the version announcement is public. Installers remain on GitHub's
/// private *source* Releases; never ship a GitHub API token to the app.
enum QaUpdatePlatform { android, windows }

class QaReleaseAnnouncement {
  const QaReleaseAnnouncement({
    required this.version,
    required this.buildNumber,
    required this.releaseTag,
  });

  final String version;
  final int buildNumber;
  final String releaseTag;

  static QaReleaseAnnouncement parse(
    String jsonText,
    QaUpdatePlatform platform,
  ) {
    final data = jsonDecode(jsonText);
    if (data is! Map<String, dynamic> ||
        data['schema'] != 1 ||
        data['product'] != 'stomni-saas-qa') {
      throw const FormatException('Not a StOmni SaaS QA announcement');
    }
    final version = data['version'];
    final build = data['build_number'];
    final tag = data['release_tag'];
    final assets = data['assets'];
    if (version is! String ||
        !RegExp(r'^[0-9]+\.[0-9]+\.[0-9]+$').hasMatch(version) ||
        build is! int ||
        build <= 0 ||
        tag is! String ||
        !RegExp(r'^saas-qa-[0-9]+\.[0-9]+\.[0-9]+-[0-9]+-attempt-[1-9][0-9]*$')
            .hasMatch(tag) ||
        !tag.startsWith('saas-qa-$version-$build-attempt-') ||
        assets is! Map<String, dynamic>) {
      throw const FormatException('Invalid QA version announcement');
    }
    final expected = platform == QaUpdatePlatform.android
        ? 'StOmni-SaaS-QA-$version-$build-android.apk'
        : 'StOmni-SaaS-QA-$version-$build-windows-x64-setup.exe';
    final asset = assets[platform.name];
    if (asset != expected) {
      throw const FormatException('Missing or inconsistent platform installer');
    }
    return QaReleaseAnnouncement(
      version: version,
      buildNumber: build,
      releaseTag: tag,
    );
  }

  bool newerThan(int installedBuild) => buildNumber > installedBuild;

  /// The authenticated browser handles access to this *private* release.
  /// No public URL and no credentials are accepted from the announcement.
  Uri get releaseUri => Uri.https(
        'github.com',
        '/fernando15xvs/StOmni_App/releases/tag/$releaseTag',
      );
}

class QaUpdateChecker {
  QaUpdateChecker({http.Client? client}) : _client = client;

  final http.Client? _client;

  static const feedUri =
      'https://raw.githubusercontent.com/fernando15xvs/StOmni_App_CI/qa-update-feed/latest.json';

  Future<QaReleaseAnnouncement?> check({
    required QaUpdatePlatform platform,
    required int installedBuild,
  }) async {
    final ownClient = _client == null;
    final client = _client ?? http.Client();
    try {
      final response = await client
          .get(Uri.parse(feedUri))
          .timeout(const Duration(seconds: 8));
      if (response.statusCode != 200 || response.bodyBytes.length > 8192) {
        return null;
      }
      final announcement = QaReleaseAnnouncement.parse(
        utf8.decode(response.bodyBytes),
        platform,
      );
      return announcement.newerThan(installedBuild) ? announcement : null;
    } on Object {
      // Offline, unavailable feed and malformed metadata must never block usage.
      return null;
    } finally {
      if (ownClient) client.close();
    }
  }
}

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
        TextButton(
          onPressed: _open,
          child: const Text('Ver actualización'),
        ),
      ],
    );
  }
}
