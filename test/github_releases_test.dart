import 'package:flutter_test/flutter_test.dart';
import 'package:proxy_app_test/github_releases.dart';

void main() {
  group('githubRepoOfFeed', () {
    test('the API address saved in older settings', () {
      expect(githubRepoOfFeed('https://api.github.com/repos/MrMultik/Multik-Sila/releases/latest'),
          'MrMultik/Multik-Sila');
    });
    test('the release page address', () {
      expect(githubRepoOfFeed('https://github.com/MrMultik/Multik-Sila/releases/latest/'),
          'MrMultik/Multik-Sila');
    });
    test('an own feed is not GitHub', () {
      expect(githubRepoOfFeed('http://10.0.2.2:18080/feed.json'), isNull);
      expect(githubRepoOfFeed('https://github.com/MrMultik/Multik-Sila/releases'), isNull);
    });
  });

  test('tag from the latest-release redirect', () {
    expect(tagFromReleaseLocation('https://github.com/MrMultik/Multik-Sila/releases/tag/v1.0.16'),
        'v1.0.16');
    expect(tagFromReleaseLocation('https://github.com/MrMultik/Multik-Sila/releases'), isNull);
    expect(tagFromReleaseLocation(null), isNull);
  });

  test('tags from a releases.atom feed, escaped copies in the content ignored', () {
    // Shape of GitHub's feed: the link of each entry, plus the same URL
    // escaped inside the HTML content.
    const atom = '''
<entry><link rel="alternate" type="text/html" href="https://github.com/XTLS/Xray-core/releases/tag/v26.9.30"/>
<content type="html">&lt;a href=&quot;https://github.com/XTLS/Xray-core/releases/tag/v26.9.30&quot;&gt;</content></entry>
<entry><link rel="alternate" type="text/html" href="https://github.com/XTLS/Xray-core/releases/tag/v26.9.9"/></entry>
<entry><link rel="alternate" type="text/html" href="https://github.com/SagerNet/sing-box/releases/tag/v1.15.0-alpha.9"/></entry>
''';
    expect(tagsFromReleasesAtom(atom), ['v26.9.30', 'v26.9.9', 'v1.15.0-alpha.9']);
  });

  group('newestCleanTag', () {
    test('by numbers, not by text', () {
      expect(newestCleanTag(['v26.9.9', 'v26.9.30', 'v26.7.28']), 'v26.9.30');
    });
    test('alphas are skipped', () {
      expect(newestCleanTag(['v1.15.0-alpha.9', 'v1.15.0-alpha.8', 'v1.14.2']), 'v1.14.2');
    });
    test('nothing clean means nothing', () {
      expect(newestCleanTag(['v1.15.0-beta.1']), isNull);
    });
  });

  test('asset addresses follow the names the releases use', () {
    expect(githubAssetUrl('MrMultik/Multik-Sila', 'v1.0.16', appApkName('1.0.16', 'x86_64')),
        'https://github.com/MrMultik/Multik-Sila/releases/download/v1.0.16/MultikSila-1.0.16-android-x86_64.apk');
    expect(appSetupName('1.0.16'), 'MultikSila-1.0.16-setup.exe');
    expect(appZipName('1.0.16'), 'MultikSila-1.0.16-windows-x64.zip');
    expect(coreWindowsAssetName('SagerNet/sing-box', '1.14.2'), 'sing-box-1.14.2-windows-amd64.zip');
    expect(coreWindowsAssetName('XTLS/Xray-core', '26.9.30'), 'Xray-windows-64.zip');
    expect(coreWindowsAssetName('someone/else', '1.0.0'), isNull);
  });

  test('version comparison', () {
    expect(compareVersionNumbers('26.9.30', '26.9.9'), greaterThan(0));
    expect(compareVersionNumbers('1.0.16', '1.0.16'), 0);
    expect(compareVersionNumbers('1.0', '1.0.1'), lessThan(0));
  });
}
