import 'package:flutter/material.dart';
import '../../models/display_render_state.dart';
import '../../models/session_event.dart';

/// Shared by desktop and mobile; never schedules recovery or infers failure.
class DisplayRenderStatus extends StatelessWidget {
  const DisplayRenderStatus({
    super.key,
    required this.model,
    required this.label,
    required this.visible,
    this.translate,
    this.inline = false,
  });
  final DisplayRenderStateModel model;
  final String Function(int display) label;
  final bool Function(int display) visible;
  final String Function(String text)? translate;
  final bool inline;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: model,
    builder: (context, _) {
      final states =
          model.states.values
              .where(
                (state) =>
                    visible(state.display) &&
                    state.phase != DisplayRenderPhase.live,
              )
              .toList()
            ..sort((a, b) => a.display.compareTo(b.display));
      if (states.isEmpty) return const SizedBox.shrink();
      final content = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final state in states)
            Text(
              '${label(state.display)}: ${_description(state.phase)} (${state.elapsedMs ~/ 1000}s)',
              style: Theme.of(context).textTheme.bodySmall,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
        ],
      );
      if (inline) return content;
      return IgnorePointer(
        child: Align(
          alignment: Alignment.topLeft,
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Material(
                color: Theme.of(
                  context,
                ).colorScheme.surface.withValues(alpha: 0.9),
                borderRadius: BorderRadius.circular(6),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  child: content,
                ),
              ),
            ),
          ),
        ),
      );
    },
  );

  String _description(DisplayRenderPhase phase) {
    final text = switch (phase) {
      DisplayRenderPhase.awaitingFrame => 'Waiting for video',
      DisplayRenderPhase.awaitingTarget => 'Waiting for renderer',
      DisplayRenderPhase.stale => 'No recent frames',
      DisplayRenderPhase.failed => 'Video unavailable',
      DisplayRenderPhase.live => '',
    };
    return translate?.call(text) ?? text;
  }
}
