/// What a remote tab does when the session it took over after login does not start.
///
/// After login the main window hands its session to a remote window, which opens a tab
/// that attaches to the session and starts its events. When that start fails, the tab used
/// to stay empty - a grey screen - while the host kept sending frames that the viewer
/// decoded and no view drew (a user's logs, 2026-11-27: 41 s, until the user opened the
/// peer again). The failure was only `debugPrint`ed, which a desktop build does not keep.
///
/// The tab now starts the session again from itself, once; the second failure is shown. A
/// start that neither finishes nor fails cannot be restarted (closing a session waits for
/// its start), so it is only logged.
class HandoffStartWatch {
  HandoffStartWatch({required this.handoff});

  /// The tab took a session over after login.
  final bool handoff;

  /// How long a handed-over start may take before it is logged as stuck. A start that
  /// works takes milliseconds; a fresh connection also logs in, which a handed-over one
  /// has done already.
  static const warnAfter = Duration(seconds: 5);

  bool _settled = false;
  bool _restartTried = false;

  /// The start finished.
  void started() => _settled = true;

  /// The start failed. Whether to start the session again from this tab: once, and only
  /// for a handed-over session.
  bool failed() {
    _settled = true;
    if (!handoff || _restartTried) return false;
    _restartTried = true;
    return true;
  }

  /// Whether the start of a handed-over session has neither finished nor failed.
  bool get stuck => handoff && !_settled;
}
