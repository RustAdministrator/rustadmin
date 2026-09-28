import 'dart:typed_data';

/// Hands one native RGBA frame to [consume].
///
/// The native buffer is a zero-copy view that stays valid only until
/// `nextRgba`, and it can be released while this handler awaits (for example
/// on the first-image UI update). It is therefore fetched after every await,
/// right before [consume] copies it synchronously.
Future<void> handleNativeRgbaFrame({
  required int Function() rgbaSize,
  required Uint8List? Function(int size) getRgba,
  required void Function() nextRgba,
  required Future<void> Function() beforeFetch,
  required bool Function() accepts,
  required Future<void> Function(Uint8List rgba) consume,
}) async {
  if (rgbaSize() == 0) {
    nextRgba();
    return;
  }
  await beforeFetch();
  if (!accepts()) {
    nextRgba();
    return;
  }
  final size = rgbaSize();
  final rgba = size == 0 ? null : getRgba(size);
  if (rgba == null) {
    nextRgba();
    return;
  }
  await consume(rgba);
}
