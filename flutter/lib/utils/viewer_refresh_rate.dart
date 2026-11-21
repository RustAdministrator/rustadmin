/// The refresh rate of the viewer's screen for the native side, in thousandths
/// of a hertz. Zero means "not known": the platform reported nothing usable.
int viewerRefreshMillihz(double? hertz) {
  if (hertz == null || !hertz.isFinite || hertz < 1 || hertz > 1000) {
    return 0;
  }
  return (hertz * 1000).round();
}

/// Reports the refresh rate only when it has changed: the callers are told
/// about every change of the window's metrics, which is every resize.
class ViewerRefreshRateReporter {
  ViewerRefreshRateReporter(this._report);

  final void Function(int millihz) _report;
  int? _last;

  void update(double? hertz) {
    final millihz = viewerRefreshMillihz(hertz);
    if (millihz == _last) return;
    _last = millihz;
    _report(millihz);
  }
}
