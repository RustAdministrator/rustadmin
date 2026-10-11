import 'dart:ui';

/// A rectangle in global coordinates as a rectangle in the coordinates of a
/// region whose top-left corner is at `regionOriginGlobal`. Null stays null.
Rect? localBlockRect(Rect? global, Offset regionOriginGlobal) {
  return global?.shift(-regionOriginGlobal);
}
