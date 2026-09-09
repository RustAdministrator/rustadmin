/// Fences queued media events and asynchronous image decodes independently of
/// keyboard, clipboard, and privacy-control permissions.
class ScreenViewAuthority {
  int _connectionGeneration = -1;
  int _generation = -1;
  int _epoch = 0;
  // Legacy web producers do not send authority snapshots. Native producers send
  // a denied snapshot on attachment, before authentication can enable media.
  bool _allowed = true;

  int get epoch => _epoch;
  bool get allowed => _allowed;
  bool accepts(int epoch) => _allowed && epoch == _epoch;

  bool apply({
    required int connectionGeneration,
    required int generation,
    required bool allowed,
  }) {
    if (connectionGeneration < _connectionGeneration ||
        generation <= _generation) {
      return false;
    }
    _connectionGeneration = connectionGeneration;
    _generation = generation;
    _allowed = allowed;
    _epoch++;
    return true;
  }

  void reset() {
    _connectionGeneration = -1;
    _generation = -1;
    _allowed = true;
    _epoch++;
  }

  void revoke() {
    _allowed = false;
    _epoch++;
  }
}
