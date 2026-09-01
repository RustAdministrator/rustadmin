import 'dart:async';

enum AndroidRenderTargetPhase { none, creating, ready, failed }

class AndroidTextureTarget {
  const AndroidTextureTarget({
    required this.display,
    required this.width,
    required this.height,
  });

  final int display;
  final int width;
  final int height;

  @override
  bool operator ==(Object other) =>
      other is AndroidTextureTarget &&
      other.display == display &&
      other.width == width &&
      other.height == height;

  @override
  int get hashCode => Object.hash(display, width, height);
}

class AndroidRenderTargetSnapshot {
  const AndroidRenderTargetSnapshot({
    required this.phase,
    this.target,
    this.textureId,
    this.producerReady = false,
  });

  static const none = AndroidRenderTargetSnapshot(
    phase: AndroidRenderTargetPhase.none,
  );

  final AndroidRenderTargetPhase phase;
  final AndroidTextureTarget? target;
  final int? textureId;
  final bool producerReady;

  bool get canRenderTexture =>
      phase == AndroidRenderTargetPhase.ready &&
      textureId != null &&
      producerReady;
}

typedef AndroidTextureCreate =
    Future<int?> Function(AndroidTextureTarget target);
typedef AndroidTextureRelease =
    Future<void> Function(AndroidTextureTarget target, int textureId);

class AndroidRenderTargetController {
  final AndroidTextureCreate _create;
  final AndroidTextureRelease _release;
  final Future<void> Function(int display) _refresh;
  final void Function() _onChanged;
  final void Function(Object error, StackTrace stackTrace) _onError;

  AndroidRenderTargetSnapshot _snapshot = AndroidRenderTargetSnapshot.none;
  AndroidTextureTarget? _desiredTarget;
  AndroidTextureTarget? _ownedTarget;
  int? _ownedTextureId;
  Future<void>? _createFuture;
  Future<void>? _retireFuture;
  final Set<Future<void>> _operations = {};
  int _generation = 0;
  int _intentEpoch = 0;

  AndroidRenderTargetController({
    required AndroidTextureCreate create,
    required AndroidTextureRelease release,
    required Future<void> Function(int display) refresh,
    required void Function() onChanged,
    required void Function(Object error, StackTrace stackTrace) onError,
  }) : _create = create,
       _release = release,
       _refresh = refresh,
       _onChanged = onChanged,
       _onError = onError;

  AndroidRenderTargetSnapshot get snapshot => _snapshot;
  int get intentEpoch => _intentEpoch;

  Future<void> requireTarget(AndroidTextureTarget target, {int? intentEpoch}) {
    if (intentEpoch != null && intentEpoch != _intentEpoch) {
      return Future<void>.value();
    }
    final retirement = _retireFuture;
    if (retirement != null) {
      return retirement.then(
        (_) => requireTarget(target, intentEpoch: intentEpoch),
      );
    }
    if (_desiredTarget == target) {
      return _createFuture ?? Future<void>.value();
    }

    _desiredTarget = target;
    final generation = ++_generation;
    if (_ownedTarget == target && _ownedTextureId != null) {
      _publish(
        AndroidRenderTargetSnapshot(
          phase: AndroidRenderTargetPhase.ready,
          target: target,
          textureId: _ownedTextureId,
        ),
      );
      return _track(_refreshTarget(target));
    }
    _publish(
      AndroidRenderTargetSnapshot(
        phase: AndroidRenderTargetPhase.creating,
        target: target,
      ),
    );
    late final Future<void> creation;
    creation = _createTarget(generation, target).whenComplete(() {
      if (identical(_createFuture, creation)) _createFuture = null;
    });
    _createFuture = creation;
    return _track(creation);
  }

  bool producerFrame({
    required int display,
    required int width,
    required int height,
    required bool active,
  }) {
    if (!active) {
      if (!_snapshot.producerReady) return false;
      _publish(
        AndroidRenderTargetSnapshot(
          phase: _snapshot.phase,
          target: _snapshot.target,
          textureId: _snapshot.textureId,
        ),
      );
      return true;
    }
    final target = _snapshot.target;
    if (_snapshot.phase != AndroidRenderTargetPhase.ready ||
        target == null ||
        target.display != display ||
        target.width != width ||
        target.height != height ||
        _snapshot.producerReady) {
      return false;
    }
    _publish(
      AndroidRenderTargetSnapshot(
        phase: AndroidRenderTargetPhase.ready,
        target: target,
        textureId: _snapshot.textureId,
        producerReady: true,
      ),
    );
    return true;
  }

  Future<void> retire({int? intentEpoch}) {
    if (intentEpoch != null && intentEpoch != _intentEpoch) {
      return Future<void>.value();
    }
    final active = _retireFuture;
    if (active != null) return active;
    _intentEpoch++;
    if (_desiredTarget == null &&
        _ownedTextureId == null &&
        _operations.isEmpty &&
        _snapshot.phase == AndroidRenderTargetPhase.none) {
      return Future<void>.value();
    }

    _desiredTarget = null;
    _generation++;
    final ownedTarget = _ownedTarget;
    final ownedTextureId = _ownedTextureId;
    _ownedTarget = null;
    _ownedTextureId = null;
    _publish(AndroidRenderTargetSnapshot.none);

    late final Future<void> retirement;
    retirement = _retire(ownedTarget, ownedTextureId).whenComplete(() {
      if (identical(_retireFuture, retirement)) _retireFuture = null;
    });
    _retireFuture = retirement;
    return retirement;
  }

  Future<void> _createTarget(
    int generation,
    AndroidTextureTarget target,
  ) async {
    int? textureId;
    try {
      textureId = await _create(target);
    } catch (error, stackTrace) {
      _fail(generation, target, error, stackTrace);
      return;
    }
    if (textureId == null) {
      if (_accepts(generation, target)) {
        _publish(
          AndroidRenderTargetSnapshot(
            phase: AndroidRenderTargetPhase.failed,
            target: target,
          ),
        );
      }
      return;
    }
    if (!_accepts(generation, target)) {
      await _safeRelease(target, textureId);
      return;
    }

    final oldTarget = _ownedTarget;
    final oldTextureId = _ownedTextureId;
    _ownedTarget = target;
    _ownedTextureId = textureId;
    _publish(
      AndroidRenderTargetSnapshot(
        phase: AndroidRenderTargetPhase.ready,
        target: target,
        textureId: textureId,
      ),
    );
    if (oldTarget != null && oldTextureId != null) {
      await _safeRelease(oldTarget, oldTextureId);
    }
    if (_accepts(generation, target)) {
      await _refreshTarget(target);
    }
  }

  Future<void> _retire(
    AndroidTextureTarget? ownedTarget,
    int? ownedTextureId,
  ) async {
    if (ownedTarget != null && ownedTextureId != null) {
      await _safeRelease(ownedTarget, ownedTextureId);
    }
    while (_operations.isNotEmpty) {
      await Future.wait(_operations.toList(), eagerError: false);
    }
  }

  Future<void> _track(Future<void> operation) {
    _operations.add(operation);
    unawaited(
      operation.then<void>(
        (_) => _operations.remove(operation),
        onError: (Object _, StackTrace __) => _operations.remove(operation),
      ),
    );
    return operation;
  }

  bool _accepts(int generation, AndroidTextureTarget target) =>
      generation == _generation && _desiredTarget == target;

  Future<void> _safeRelease(AndroidTextureTarget target, int textureId) async {
    try {
      await _release(target, textureId);
    } catch (error, stackTrace) {
      _onError(error, stackTrace);
    }
  }

  Future<void> _refreshTarget(AndroidTextureTarget target) async {
    try {
      await _refresh(target.display);
    } catch (error, stackTrace) {
      _onError(error, stackTrace);
      if (_desiredTarget == target) {
        _publish(
          AndroidRenderTargetSnapshot(
            phase: AndroidRenderTargetPhase.failed,
            target: target,
          ),
        );
      }
    }
  }

  void _fail(
    int generation,
    AndroidTextureTarget target,
    Object error,
    StackTrace stackTrace,
  ) {
    _onError(error, stackTrace);
    if (_accepts(generation, target)) {
      _publish(
        AndroidRenderTargetSnapshot(
          phase: AndroidRenderTargetPhase.failed,
          target: target,
        ),
      );
    }
  }

  void _publish(AndroidRenderTargetSnapshot snapshot) {
    if (identical(_snapshot, snapshot)) return;
    _snapshot = snapshot;
    _onChanged();
  }
}
