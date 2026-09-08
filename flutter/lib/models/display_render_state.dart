import 'dart:collection';
import 'package:flutter/foundation.dart';
import 'session_event.dart';

/// Projection only. Rust owns startup, failure, staleness, and elapsed time.
class DisplayRenderStateModel extends ChangeNotifier {
  final _states = <int, DisplayRenderStateSessionEvent>{};
  int _connection = -1;
  int _authority = -1;
  bool _allowed = false;

  Map<int, DisplayRenderStateSessionEvent> get states =>
      UnmodifiableMapView(_states);

  void setAuthority(ScreenViewAuthoritySessionEvent event) {
    if (event.connectionGeneration < _connection ||
        (event.connectionGeneration == _connection &&
            event.generation <= _authority)) {
      return;
    }
    _connection = event.connectionGeneration;
    _authority = event.generation;
    _allowed = event.allowed;
    _states.clear();
    notifyListeners();
  }

  bool apply(DisplayRenderStateSessionEvent event) {
    if (!_allowed ||
        event.connectionGeneration != _connection ||
        event.authorityGeneration != _authority) {
      return false;
    }
    final previous = _states[event.display];
    if (previous != null &&
        (event.sequence <= previous.sequence ||
            event.activationGeneration < previous.activationGeneration)) {
      return false;
    }
    _states[event.display] = event;
    notifyListeners();
    return true;
  }

  void clear({bool reset = false}) {
    _allowed = false;
    if (reset) {
      _connection = -1;
      _authority = -1;
    }
    _states.clear();
    notifyListeners();
  }
}
