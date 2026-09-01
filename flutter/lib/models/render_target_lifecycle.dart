class RenderTargetLifecycle {
  bool _retired = false;
  Future<void>? _creation;
  Future<void>? _retirement;

  bool get mayRegister => !_retired;

  void trackCreation(Future<void> creation) {
    if (_creation != null) {
      throw StateError('Render target creation is already tracked');
    }
    _creation = creation;
  }

  Future<void> retire(Future<void> Function() cleanup) {
    return _retirement ??= _retire(cleanup);
  }

  Future<void> _retire(Future<void> Function() cleanup) async {
    _retired = true;
    try {
      final creation = _creation;
      if (creation != null) {
        await creation;
      }
    } finally {
      await cleanup();
    }
  }
}
