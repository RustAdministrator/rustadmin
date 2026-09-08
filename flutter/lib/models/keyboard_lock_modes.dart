/// Existing Flutter/Rust bridge `lock_modes`, not the protobuf V2 lock mask.
/// Rust converts these 2/4/8 bits to V2's 1/2/4 exactly once at the wire boundary.
abstract final class KeyboardBridgeLockModes {
  static const caps = 1 << 1;
  static const num = 1 << 2;
  static const scroll = 1 << 3;
  static const known = caps | num | scroll;

  static bool isValid(int value) => value >= 0 && (value & ~known) == 0;
}
