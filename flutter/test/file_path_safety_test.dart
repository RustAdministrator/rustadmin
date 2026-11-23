import 'package:flutter_hbb/models/file_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('entry names from a listing', () {
    test('a plain name is one component on the destination system', () {
      for (final name in ['report.txt', '.hidden', 'a b', '..x', 'a..b', 'ё']) {
        expect(PathUtil.isPlainEntryName(name, false), isTrue, reason: name);
        expect(PathUtil.isPlainEntryName(name, true), isTrue, reason: name);
      }
      for (final name in ['', '.', '..', '/etc/x', 'a/b', '../x', 'a\u0000b']) {
        expect(PathUtil.isPlainEntryName(name, false), isFalse, reason: name);
        expect(PathUtil.isPlainEntryName(name, true), isFalse, reason: name);
      }
      // A backslash and a colon are ordinary characters in a POSIX name and
      // parts of a path on Windows.
      for (final name in [
        r'a\b',
        r'..\x',
        r'C:\x',
        'C:x',
        'x:stream',
        r'\\server\share',
      ]) {
        expect(PathUtil.isPlainEntryName(name, true), isFalse, reason: name);
        expect(PathUtil.isPlainEntryName(name, false), isTrue, reason: name);
      }
    });

    test('the destination of an entry stays inside the chosen folder', () {
      expect(
        PathUtil.joinEntryName('/home/user/Downloads', 'report.txt', false),
        '/home/user/Downloads/report.txt',
      );
      expect(
        PathUtil.joinEntryName(r'C:\Users\user\Downloads', 'report.txt', true),
        r'C:\Users\user\Downloads\report.txt',
      );

      // What PathUtil.join made of these names is in the comments.
      // -> /etc/cron.d/job
      expect(
        PathUtil.joinEntryName(
          '/home/user/Downloads',
          '/etc/cron.d/job',
          false,
        ),
        isNull,
      );
      // -> /home/user/Downloads/../.ssh/authorized_keys
      expect(
        PathUtil.joinEntryName(
          '/home/user/Downloads',
          '../.ssh/authorized_keys',
          false,
        ),
        isNull,
      );
      // -> C:\Users\Public\x.bat
      expect(
        PathUtil.joinEntryName(
          r'C:\Users\user\Downloads',
          r'C:\Users\Public\x.bat',
          true,
        ),
        isNull,
      );
      // -> C:\Users\user\Downloads\..\..\x.bat
      expect(
        PathUtil.joinEntryName(
          r'C:\Users\user\Downloads',
          r'..\..\x.bat',
          true,
        ),
        isNull,
      );
      // -> \\server\share\x
      expect(
        PathUtil.joinEntryName(
          r'C:\Users\user\Downloads',
          r'\\server\share\x',
          true,
        ),
        isNull,
      );
    });
  });

  group('empty folders reported by the other side', () {
    test('a folder inside the transferred folder keeps its relative place', () {
      expect(
        PathUtil.getOtherSidePathInside(
          '/srv/data',
          '/srv/data/photos/2024/empty',
          false,
          r'C:\in',
          true,
        ),
        r'C:\in\photos\2024\empty',
      );
      expect(
        PathUtil.getOtherSidePathInside(
          r'D:\data',
          r'D:\data\photos\empty',
          true,
          '/home/user/in',
          false,
        ),
        '/home/user/in/photos/empty',
      );
    });

    test('a folder outside the transferred folder has no place', () {
      // The user opened another folder while the list was fetched, or the
      // other side reported a path of its own choice.
      expect(
        PathUtil.getOtherSidePathInside(
          '/srv/data',
          '/srv/other/empty',
          false,
          '/home/user/in',
          false,
        ),
        isNull,
      );
      expect(
        PathUtil.getOtherSidePathInside(
          '/srv/data/deep',
          '/etc',
          false,
          '/home/user/in',
          false,
        ),
        isNull,
      );
      expect(
        PathUtil.getOtherSidePathInside(
          r'D:\data',
          r'E:\x',
          true,
          '/home/user/in',
          false,
        ),
        isNull,
      );
      // The same input through the unchecked function leaves the destination.
      expect(
        PathUtil.getOtherSidePath(
          '/srv/data',
          '/srv/other/empty',
          false,
          '/home/user/in',
          false,
        ),
        '/home/user/in/../other/empty',
      );
    });

    test(
      'a component that is a path on the destination system has no place',
      () {
        expect(
          PathUtil.getOtherSidePathInside(
            '/srv/data',
            r'/srv/data/a\..\..\b',
            false,
            r'C:\in',
            true,
          ),
          isNull,
        );
        expect(
          PathUtil.getOtherSidePathInside(
            '/srv/data',
            '/srv/data/x:y',
            false,
            r'C:\in',
            true,
          ),
          isNull,
        );
      },
    );
  });
}
