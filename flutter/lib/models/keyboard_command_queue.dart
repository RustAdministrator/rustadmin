typedef KeyboardCommandErrorHandler =
    void Function(Object error, StackTrace stackTrace);

class KeyboardCommandQueue {
  KeyboardCommandQueue({this.onError});

  final KeyboardCommandErrorHandler? onError;
  Future<void> _tail = Future<void>.value();
  var _generation = 0;

  Future<void> enqueue(Future<void> Function() command) {
    final generation = _generation;
    _tail = _tail.then((_) async {
      if (generation != _generation) return;
      try {
        await command();
      } catch (error, stackTrace) {
        onError?.call(error, stackTrace);
      }
    });
    return _tail;
  }

  void cancelPending() {
    _generation++;
  }
}
