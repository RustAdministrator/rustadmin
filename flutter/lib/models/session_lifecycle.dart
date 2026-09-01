enum SessionPhase { created, connecting, connected, closing, closed, failed }

class SessionLifecycle {
  var _generation = 0;
  var _phase = SessionPhase.created;

  int get generation => _generation;
  SessionPhase get phase => _phase;
  bool get isClosed =>
      _phase == SessionPhase.closed || _phase == SessionPhase.failed;

  int beginStart() {
    _phase = SessionPhase.connecting;
    return ++_generation;
  }

  int beginClose() {
    _phase = SessionPhase.closing;
    return ++_generation;
  }

  bool accepts(int generation) =>
      generation == _generation && _phase != SessionPhase.closing && !isClosed;

  void connected(int generation) {
    if (generation == _generation && _phase == SessionPhase.connecting) {
      _phase = SessionPhase.connected;
    }
  }

  void closed(int generation) {
    if (generation == _generation) {
      _phase = SessionPhase.closed;
    }
  }

  void failed(int generation) {
    if (generation == _generation) {
      _phase = SessionPhase.failed;
    }
  }
}
