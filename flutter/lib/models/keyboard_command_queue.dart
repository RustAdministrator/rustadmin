typedef KeyboardCommandErrorHandler =
    void Function(Object error, StackTrace stackTrace);

class KeyboardCommandQueue {
  KeyboardCommandQueue({this.onError});

  final KeyboardCommandErrorHandler? onError;
  Future<void> _tail = Future<void>.value();

  Future<void> enqueue(Future<void> Function() command) {
    _tail = _tail.then((_) async {
      try {
        await command();
      } catch (error, stackTrace) {
        onError?.call(error, stackTrace);
      }
    });
    return _tail;
  }
}
