import 'package:flutter/foundation.dart';

enum MobileModifierKey { ctrl, alt, shift, command }

enum MobileModifierMode {
  off,
  oneShot,
  locked;

  bool get active => this != MobileModifierMode.off;
}

class MobileModifierState extends ChangeNotifier {
  final List<MobileModifierMode> _modes = List<MobileModifierMode>.filled(
    MobileModifierKey.values.length,
    MobileModifierMode.off,
  );

  MobileModifierMode modeFor(MobileModifierKey key) => _modes[key.index];

  bool isActive(MobileModifierKey key) => modeFor(key).active;

  bool get hasActive => _modes.any((mode) => mode.active);

  void tap(MobileModifierKey key) {
    final next = modeFor(key) == MobileModifierMode.off
        ? MobileModifierMode.oneShot
        : MobileModifierMode.off;
    _setMode(key, next);
  }

  void lock(MobileModifierKey key) {
    _setMode(key, MobileModifierMode.locked);
  }

  bool consumeOneShot() {
    var changed = false;
    for (var index = 0; index < _modes.length; index++) {
      if (_modes[index] == MobileModifierMode.oneShot) {
        _modes[index] = MobileModifierMode.off;
        changed = true;
      }
    }
    if (changed) notifyListeners();
    return changed;
  }

  bool reset() {
    var changed = false;
    for (var index = 0; index < _modes.length; index++) {
      if (_modes[index] != MobileModifierMode.off) {
        _modes[index] = MobileModifierMode.off;
        changed = true;
      }
    }
    if (changed) notifyListeners();
    return changed;
  }

  void _setMode(MobileModifierKey key, MobileModifierMode mode) {
    if (_modes[key.index] == mode) return;
    _modes[key.index] = mode;
    notifyListeners();
  }
}
