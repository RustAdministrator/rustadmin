import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/utils/window_placement.dart';

WindowDisplay display({
  String? id,
  required Rect workArea,
  double scaleFactor = 1,
  bool isPrimary = false,
}) {
  return WindowDisplay(
    id: id,
    workArea: workArea,
    scaleFactor: scaleFactor,
    isPrimary: isPrimary,
  );
}

void main() {
  test('serializes valid displays and rejects malformed numeric data', () {
    final original = display(
      id: 'primary',
      workArea: const Rect.fromLTWH(-1920, 24, 1920, 1056),
      scaleFactor: 1.5,
      isPrimary: true,
    );

    expect(original.toJson(), <String, dynamic>{
      'id': 'primary',
      'workArea': <String, dynamic>{
        'l': -1920.0,
        't': 24.0,
        'r': 0.0,
        'b': 1080.0,
      },
      'scaleFactor': 1.5,
      'isPrimary': true,
    });
    expect(WindowDisplay.fromJson(original.toJson()), original);
    expect(WindowDisplay.fromJson(42), isNull);
    expect(
      WindowDisplay.fromJson(<String, dynamic>{
        'visibleFrame': <String, dynamic>{'l': 0, 't': 0, 'r': 100, 'b': 100},
        'scaleFactor': 1,
      }),
      isNull,
    );
    expect(
      WindowDisplay.fromJson(<String, dynamic>{
        'workArea': <String, dynamic>{
          'x': 0,
          'y': 0,
          'width': 100,
          'height': 100,
        },
        'scaleFactor': 1,
      }),
      isNull,
    );
    expect(
      WindowDisplay.fromJson(<String, dynamic>{
        'workArea': <String, dynamic>{
          'l': 0,
          't': 0,
          'r': double.nan,
          'b': 900,
        },
        'scaleFactor': 1,
      }),
      isNull,
    );
    expect(
      WindowDisplay.fromJson(<String, dynamic>{
        'workArea': <String, dynamic>{'l': 0, 't': 0, 'r': 100, 'b': 100},
        'scaleFactor': 0,
      }),
      isNull,
    );
    expect(
      WindowDisplay.fromJson(<String, dynamic>{
        'workArea': <String, dynamic>{'l': 0, 't': 0, 'r': 100, 'b': 100},
        'scaleFactor': '2',
      }),
      isNull,
    );
  });

  test(
    'uses the primary display for first launch and scales defaults when asked',
    () {
      final primary = display(
        id: 'primary',
        workArea: const Rect.fromLTWH(-1200, 40, 1200, 760),
        scaleFactor: 1.5,
        isPrimary: true,
      );
      final secondary = display(
        id: 'secondary',
        workArea: const Rect.fromLTWH(0, 0, 1600, 900),
      );

      final placement = restoreWindowPlacement(
        displays: <WindowDisplay>[secondary, primary],
        defaultSize: const Size(400, 200),
        scaleDefaultSize: true,
      );

      expect(placement?.display, primary);
      expect(placement?.frame, const Rect.fromLTWH(-900, 270, 600, 300));
    },
  );

  test('returns null when no valid display or default geometry exists', () {
    expect(
      restoreWindowPlacement(
        displays: <WindowDisplay>[
          display(workArea: const Rect.fromLTWH(0, 0, 0, 900), isPrimary: true),
          display(
            workArea: const Rect.fromLTWH(0, 0, 1200, 900),
            scaleFactor: double.nan,
          ),
        ],
        defaultSize: const Size(400, 200),
      ),
      isNull,
    );
    expect(
      restoreWindowPlacement(
        displays: <WindowDisplay>[
          display(
            workArea: const Rect.fromLTWH(0, 0, 1200, 900),
            isPrimary: true,
          ),
        ],
        defaultSize: const Size(double.nan, 200),
      ),
      isNull,
    );
  });

  test('maps a saved monitor offset and size across displays and DPI', () {
    final savedDisplay = display(
      id: 'panel',
      workArea: const Rect.fromLTWH(-1920, 40, 1920, 1040),
      scaleFactor: 1,
    );
    final currentDisplay = display(
      id: 'panel',
      workArea: const Rect.fromLTWH(100, 80, 2560, 1400),
      scaleFactor: 2,
      isPrimary: true,
    );
    final savedFrame = const Rect.fromLTWH(-1720, 140, 800, 600);

    final placement = restoreWindowPlacement(
      displays: <WindowDisplay>[currentDisplay],
      defaultSize: const Size(400, 300),
      savedFrame: savedFrame,
      savedDisplay: savedDisplay,
    );

    expect(placement?.display, currentDisplay);
    expect(placement?.frame, const Rect.fromLTWH(500, 280, 1600, 1200));
  });

  test(
    'preserves a same-display frame, then clamps and fits oversize frames',
    () {
      final monitor = display(
        id: 'same',
        workArea: const Rect.fromLTWH(-100, -50, 400, 300),
        scaleFactor: 1,
        isPrimary: true,
      );
      final savedDisplay = display(
        id: 'same',
        workArea: monitor.workArea,
        scaleFactor: 1,
      );

      final placement = restoreWindowPlacement(
        displays: <WindowDisplay>[monitor],
        defaultSize: const Size(100, 100),
        savedFrame: const Rect.fromLTWH(-500, -500, 600, 500),
        savedDisplay: savedDisplay,
      );

      expect(placement?.frame, monitor.workArea);
    },
  );

  test(
    'uses the old work area to disambiguate duplicate display identifiers',
    () {
      final primary = display(
        id: 'duplicate',
        workArea: const Rect.fromLTWH(0, 0, 1200, 900),
        isPrimary: true,
      );
      final secondary = display(
        id: 'duplicate',
        workArea: const Rect.fromLTWH(1200, -80, 1600, 1000),
      );
      final savedDisplay = display(
        id: 'duplicate',
        workArea: secondary.workArea,
      );
      final savedFrame = const Rect.fromLTWH(1300, 20, 500, 400);

      final placement = restoreWindowPlacement(
        displays: <WindowDisplay>[primary, secondary],
        defaultSize: const Size(300, 200),
        savedFrame: savedFrame,
        savedDisplay: savedDisplay,
      );

      expect(placement?.display, secondary);
      expect(placement?.frame, savedFrame);
    },
  );

  test('matches an unnamed monitor by its unique exact area and scale', () {
    final primary = display(
      id: 'primary',
      workArea: const Rect.fromLTWH(0, 0, 1000, 800),
      isPrimary: true,
    );
    final unnamed = display(
      workArea: const Rect.fromLTWH(-1200, 0, 1200, 900),
      scaleFactor: 1.5,
    );
    final savedFrame = const Rect.fromLTWH(-1100, 100, 500, 400);

    final placement = restoreWindowPlacement(
      displays: <WindowDisplay>[primary, unnamed],
      defaultSize: const Size(300, 200),
      savedFrame: savedFrame,
      savedDisplay: display(
        workArea: unnamed.workArea,
        scaleFactor: unnamed.scaleFactor,
      ),
    );

    expect(placement?.display, unnamed);
    expect(placement?.frame, savedFrame);
  });

  test('does not use old coordinates when a stored monitor is unavailable', () {
    final primary = display(
      id: 'primary',
      workArea: const Rect.fromLTWH(0, 0, 1000, 800),
      isPrimary: true,
    );
    final unrelated = display(
      id: 'current-secondary',
      workArea: const Rect.fromLTWH(1000, 0, 1200, 900),
    );
    final savedDisplay = display(
      id: 'disconnected',
      workArea: unrelated.workArea,
      scaleFactor: 1,
    );

    final placement = restoreWindowPlacement(
      displays: <WindowDisplay>[primary, unrelated],
      defaultSize: const Size(300, 200),
      savedFrame: const Rect.fromLTWH(1100, 100, 400, 300),
      savedDisplay: savedDisplay,
    );

    expect(placement?.display, primary);
    expect(placement?.frame, const Rect.fromLTWH(300, 250, 400, 300));
  });

  test(
    'legacy frame uses greatest overlap and centers on primary when disconnected',
    () {
      final primary = display(
        id: 'primary',
        workArea: const Rect.fromLTWH(0, 0, 1000, 800),
        isPrimary: true,
      );
      final secondary = display(
        id: 'secondary',
        workArea: const Rect.fromLTWH(-1200, -100, 1200, 900),
      );

      final overlapping = restoreWindowPlacement(
        displays: <WindowDisplay>[primary, secondary],
        defaultSize: const Size(300, 200),
        savedFrame: const Rect.fromLTWH(-1100, 0, 500, 400),
      );
      expect(overlapping?.display, secondary);
      expect(overlapping?.frame, const Rect.fromLTWH(-1100, 0, 500, 400));

      final disconnected = restoreWindowPlacement(
        displays: <WindowDisplay>[primary, secondary],
        defaultSize: const Size(300, 200),
        savedFrame: const Rect.fromLTWH(3000, 3000, 500, 400),
      );
      expect(disconnected?.display, primary);
      expect(disconnected?.frame, const Rect.fromLTWH(250, 200, 500, 400));
    },
  );

  test(
    'displayForWindow filters invalid displays and chooses greatest overlap',
    () {
      final primary = display(
        id: 'primary',
        workArea: const Rect.fromLTWH(-1000, 0, 1000, 800),
        isPrimary: true,
      );
      final secondary = display(
        id: 'secondary',
        workArea: const Rect.fromLTWH(0, 0, 1600, 900),
      );
      final invalid = display(
        id: 'invalid',
        workArea: const Rect.fromLTWH(0, 0, 1600, 900),
        scaleFactor: 0,
      );

      expect(
        displayForWindow(
          const Rect.fromLTWH(100, 100, 800, 600),
          <WindowDisplay>[invalid, primary, secondary],
        ),
        secondary,
      );
      expect(
        displayForWindow(
          const Rect.fromLTWH(3000, 100, 800, 600),
          <WindowDisplay>[invalid, primary, secondary],
        ),
        primary,
      );
    },
  );
}
