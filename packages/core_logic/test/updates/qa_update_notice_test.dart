import 'package:core_logic/updates/qa_update_notice.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const releaseJson = '''
{
  "schema": 1,
  "product": "stomni-saas-qa",
  "version": "2.0.1",
  "build_number": 10002,
  "release_tag": "saas-qa-2.0.1-10002-attempt-1",
  "assets": {
    "android": "StOmni-SaaS-QA-2.0.1-10002-android.apk",
    "windows": "StOmni-SaaS-QA-2.0.1-10002-windows-x64-setup.exe"
  }
}
''';

void main() {
  test('Android checks only strictly newer QA builds', () {
    final release = QaReleaseAnnouncement.parse(
      releaseJson,
      QaUpdatePlatform.android,
    );
    expect(release.newerThan(10001), isTrue);
    expect(release.newerThan(10002), isFalse);
    expect(release.newerThan(10003), isFalse);
  });

  test('Windows opens only a source-private GitHub release', () {
    final release = QaReleaseAnnouncement.parse(
      releaseJson,
      QaUpdatePlatform.windows,
    );
    expect(
      release.releaseUri.toString(),
      'https://github.com/fernando15xvs/StOmni_App/releases/tag/'
      'saas-qa-2.0.1-10002-attempt-1',
    );
  });

  test('rejects inconsistent asset and unsafe release tag', () {
    expect(
      () => QaReleaseAnnouncement.parse(
        releaseJson.replaceFirst('10002-android.apk', '10001-android.apk'),
        QaUpdatePlatform.android,
      ),
      throwsFormatException,
    );
    expect(
      () => QaReleaseAnnouncement.parse(
        releaseJson.replaceFirst('attempt-1', '../other'),
        QaUpdatePlatform.windows,
      ),
      throwsFormatException,
    );
  });

  test('HTTP failures never block application', () async {
    final client = MockClient(
      (request) async => http.Response('unavailable', 503),
    );
    final result = await QaUpdateChecker(client: client).check(
      platform: QaUpdatePlatform.android,
      installedBuild: 10001,
    );
    expect(result, isNull);
    client.close();
  });

  test('detects a newer build from CI feed without private token', () async {
    final client = MockClient((request) async {
      expect(request.url.toString(), QaUpdateChecker.feedUri);
      expect(request.headers.containsKey('authorization'), isFalse);
      return http.Response(releaseJson, 200);
    });
    final result = await QaUpdateChecker(client: client).check(
      platform: QaUpdatePlatform.android,
      installedBuild: 10001,
    );
    expect(result?.buildNumber, 10002);
    client.close();
  });
}
