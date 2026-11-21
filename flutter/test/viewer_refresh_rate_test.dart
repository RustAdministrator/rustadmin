import 'package:flutter_hbb/utils/viewer_refresh_rate.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('refresh rate is passed in thousandths of a hertz', () {
    expect(viewerRefreshMillihz(60), 60000);
    expect(viewerRefreshMillihz(59.94), 59940);
    expect(viewerRefreshMillihz(143.998), 143998);
  });

  test('a rate the platform cannot name is passed as unknown', () {
    expect(viewerRefreshMillihz(null), 0);
    expect(viewerRefreshMillihz(0), 0);
    expect(viewerRefreshMillihz(-60), 0);
    expect(viewerRefreshMillihz(double.nan), 0);
    expect(viewerRefreshMillihz(double.infinity), 0);
    expect(viewerRefreshMillihz(100000), 0);
  });

  test('only a change is reported', () {
    final reported = <int>[];
    final reporter = ViewerRefreshRateReporter(reported.add);
    reporter.update(60);
    reporter.update(60);
    reporter.update(60.0001);
    reporter.update(144);
    reporter.update(null);
    reporter.update(null);
    expect(reported, [60000, 144000, 0]);
  });
}
