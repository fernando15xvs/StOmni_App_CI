import 'dart:convert';

import 'package:http/http.dart' as http;

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
        !RegExp(
          r'^saas-qa-[0-9]+\.[0-9]+\.[0-9]+-[0-9]+-attempt-[1-9][0-9]*$',
        ).hasMatch(tag) ||
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
