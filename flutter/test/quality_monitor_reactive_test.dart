import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_hbb/common/widgets/overlay.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('quality monitor applies streamed settings without polling', (
    tester,
  ) async {
    const initial = QualityMonitorFadeSettings(
      opacity: 0.5,
      delay: Duration(seconds: 10),
      duration: Duration(milliseconds: 300),
    );
    const updated = QualityMonitorFadeSettings(
      opacity: 0.25,
      delay: Duration.zero,
      duration: Duration.zero,
    );
    final changes = StreamController<QualityMonitorFadeSettings>();
    addTearDown(changes.close);

    await tester.pumpWidget(
      MaterialApp(
        home: QualityMonitorHoverFade(
          settingsProvider: () => initial,
          settingsStream: changes.stream,
          child: const SizedBox(width: 100, height: 100),
        ),
      ),
    );

    changes.add(updated);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));

    final opacity = tester.widget<AnimatedOpacity>(
      find.byType(AnimatedOpacity),
    );
    expect(opacity.opacity, 0.25);
    expect(opacity.duration, Duration.zero);
  });
}
