import 'package:flutter/material.dart';
import 'package:flutter_hbb/common/widgets/display_render_status.dart';
import 'package:flutter_hbb/models/display_render_state.dart';
import 'package:flutter_hbb/models/session_event.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> event({
  int display = 0,
  String state = 'awaiting-frame',
  int connection = 1,
  int authority = 2,
  int activation = 3,
  int sequence = 1,
  int age = 0,
}) => {
  'name': 'display_render_state',
  'display': display,
  'state': state,
  'connection_generation': connection,
  'screen_authority_generation': authority,
  'display_activation_generation': activation,
  'render_target_generation': 0,
  'stream_id': 0,
  'submitted_frame_id': 0,
  'sequence': sequence,
  'elapsed_ms': age,
  'presentation_confirmed': false,
};

DisplayRenderStateSessionEvent decode(Map<String, dynamic> value) =>
    decodeTypedSessionEvent(value)! as DisplayRenderStateSessionEvent;

void authorize(
  DisplayRenderStateModel model, {
  int connection = 1,
  int generation = 2,
  bool allowed = true,
}) {
  model.setAuthority(
    ScreenViewAuthoritySessionEvent(
      connectionGeneration: connection,
      generation: generation,
      allowed: allowed,
    ),
  );
}

void main() {
  test('typed liveness decoder rejects malformed or presentation claims', () {
    for (final phase in [
      'awaiting-frame',
      'awaiting-target',
      'live',
      'stale',
      'failed',
    ]) {
      expect(
        decodeTypedSessionEvent(event(state: phase)),
        isA<DisplayRenderStateSessionEvent>(),
      );
    }
    for (final change in [
      {'state': 'connected'},
      {'display': -1},
      {'sequence': 0},
      {'display_activation_generation': 0},
      {'elapsed_ms': '1'},
      {'presentation_confirmed': true},
      {'stream_id': null},
    ]) {
      expect(
        decodeTypedSessionEvent({...event(), ...change}),
        isA<InvalidSessionEvent>(),
      );
    }
  });

  test('status is authority fenced and rejects late per-display events', () {
    final model = DisplayRenderStateModel();
    addTearDown(model.dispose);
    expect(model.apply(decode(event())), isFalse);
    authorize(model);
    expect(model.apply(decode(event(state: 'live', sequence: 2))), isTrue);
    expect(model.apply(decode(event(sequence: 1))), isFalse);
    expect(model.apply(decode(event(activation: 2, sequence: 3))), isFalse);
    expect(model.apply(decode(event(connection: 0, sequence: 4))), isFalse);
    expect(model.apply(decode(event(authority: 1, sequence: 5))), isFalse);
    expect(
      model.apply(decode(event(display: 1, state: 'failed', sequence: 1))),
      isTrue,
    );
    expect(model.states[0]!.phase, DisplayRenderPhase.live);
    expect(model.states[1]!.phase, DisplayRenderPhase.failed);
    authorize(model, generation: 3, allowed: false);
    expect(model.states, isEmpty);
    expect(model.apply(decode(event(authority: 3, sequence: 6))), isFalse);
    authorize(model, connection: 2, generation: 1);
    expect(model.apply(decode(event(connection: 2, authority: 1))), isTrue);
    model.clear();
    expect(model.states, isEmpty);
    expect(
      model.apply(decode(event(connection: 2, authority: 1, sequence: 2))),
      isFalse,
    );
  });

  for (final size in [const Size(360, 640), const Size(1280, 800)]) {
    testWidgets(
      'shared mobile/desktop status preserves cached content at $size',
      (tester) async {
        await tester.binding.setSurfaceSize(size);
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final model = DisplayRenderStateModel();
        addTearDown(model.dispose);
        authorize(model);
        model.apply(decode(event(state: 'stale', age: 9000)));
        model.apply(decode(event(display: 1, state: 'live')));
        model.apply(decode(event(display: 2, state: 'failed')));
        var taps = 0;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Stack(
                children: [
                  Positioned.fill(
                    child: GestureDetector(
                      onTap: () => taps++,
                      child: const ColoredBox(
                        color: Colors.blue,
                        child: Text('Cached desktop'),
                      ),
                    ),
                  ),
                  DisplayRenderStatus(
                    model: model,
                    label: (display) => 'Display ${display + 1}',
                    visible: (display) => display < 2,
                  ),
                ],
              ),
            ),
          ),
        );
        expect(find.text('Display 1: No recent frames (9s)'), findsOneWidget);
        expect(find.textContaining('Video unavailable'), findsNothing);
        expect(find.text('Cached desktop'), findsOneWidget);
        await tester.tapAt(const Offset(20, 20));
        expect(taps, 1);
        // Wall time does not invent a UI failure or advance native-provided age.
        await tester.pump(const Duration(minutes: 5));
        expect(find.text('Display 1: No recent frames (9s)'), findsOneWidget);
        model.apply(decode(event(state: 'failed', age: 110000, sequence: 2)));
        await tester.pump();
        expect(
          find.text('Display 1: Video unavailable (110s)'),
          findsOneWidget,
        );
        model.apply(decode(event(state: 'live', sequence: 3)));
        await tester.pump();
        expect(find.textContaining('Display 1:'), findsNothing);
        expect(find.text('Cached desktop'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('waiting dialog can show failed status inline', (tester) async {
    final model = DisplayRenderStateModel();
    addTearDown(model.dispose);
    authorize(model);
    model.apply(decode(event(state: 'failed', age: 95000)));
    await tester.pumpWidget(
      MaterialApp(
        home: AlertDialog(
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Waiting for image'),
              DisplayRenderStatus(
                model: model,
                inline: true,
                label: (_) => 'Display 1',
                translate: (text) => 'translated $text',
                visible: (_) => true,
              ),
            ],
          ),
        ),
      ),
    );
    expect(
      find.text('Display 1: translated Video unavailable (95s)'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
}
