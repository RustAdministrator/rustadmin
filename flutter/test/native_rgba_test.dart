import 'dart:typed_data';

import 'package:flutter_hbb/models/native_rgba.dart';
import 'package:flutter_test/flutter_test.dart';

/// Models the native display buffer: a view is only valid until the buffer is
/// released, after which its memory holds unrelated bytes.
class _FakeNativeRgba {
  Uint8List buffer = Uint8List.fromList([1, 2, 3, 4]);
  int nextCalls = 0;

  int size() => buffer.length;

  Uint8List? view(int size) => Uint8List.sublistView(buffer, 0, size);

  void releaseAndReuse() {
    // The old allocation is reused for unrelated data; a new frame replaces it.
    buffer.fillRange(0, buffer.length, 0xEE);
    buffer = Uint8List.fromList([5, 6, 7, 8]);
  }
}

void main() {
  test('the native view is fetched after the pre-render await', () async {
    final native = _FakeNativeRgba();
    List<int>? consumed;
    await handleNativeRgbaFrame(
      rgbaSize: native.size,
      getRgba: native.view,
      nextRgba: () => native.nextCalls++,
      beforeFetch: () async {
        await Future<void>.delayed(Duration.zero);
        native.releaseAndReuse();
      },
      accepts: () => true,
      // Copy synchronously, like ImmutableBuffer.fromUint8List does.
      consume: (rgba) async => consumed = List<int>.of(rgba),
    );
    expect(consumed, [5, 6, 7, 8]);
    expect(native.nextCalls, 0, reason: 'the consumer calls nextRgba');
  });

  test('frames are released without a consumer when not accepted', () async {
    final native = _FakeNativeRgba();
    var consumed = false;
    await handleNativeRgbaFrame(
      rgbaSize: native.size,
      getRgba: native.view,
      nextRgba: () => native.nextCalls++,
      beforeFetch: () async {},
      accepts: () => false,
      consume: (_) async => consumed = true,
    );
    expect(consumed, isFalse);
    expect(native.nextCalls, 1);
  });

  test('a buffer released during the await is skipped', () async {
    final native = _FakeNativeRgba();
    var consumed = false;
    await handleNativeRgbaFrame(
      rgbaSize: native.size,
      getRgba: native.view,
      nextRgba: () => native.nextCalls++,
      beforeFetch: () async => native.buffer = Uint8List(0),
      accepts: () => true,
      consume: (_) async => consumed = true,
    );
    expect(consumed, isFalse);
    expect(native.nextCalls, 1);
  });

  test('an empty frame is released immediately', () async {
    final native = _FakeNativeRgba()..buffer = Uint8List(0);
    var fetched = false;
    await handleNativeRgbaFrame(
      rgbaSize: native.size,
      getRgba: native.view,
      nextRgba: () => native.nextCalls++,
      beforeFetch: () async => fetched = true,
      accepts: () => true,
      consume: (_) async {},
    );
    expect(fetched, isFalse);
    expect(native.nextCalls, 1);
  });
}
