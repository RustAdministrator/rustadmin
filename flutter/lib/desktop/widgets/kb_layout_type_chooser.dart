import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_hbb/common/session_peer_settings.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/models/keyboard_intent.dart';
import 'package:flutter_hbb/models/model.dart';

import '../../common.dart';

const _kPhysicalKeyboardFamilyAuto = 'auto';
const _kPhysicalKeyboardFamilyAnsi = 'ansi';
const _kPhysicalKeyboardFamilyIso = 'iso';
const _kPhysicalKeyboardFamilyJis = 'jis';

final class _PhysicalKeyboardFamilyOption {
  const _PhysicalKeyboardFamilyOption({
    required this.value,
    required this.label,
    required this.description,
  });

  final String value;
  final String label;
  final String description;
}

const _physicalKeyboardFamilyOptions = [
  _PhysicalKeyboardFamilyOption(
    value: _kPhysicalKeyboardFamilyAuto,
    label: 'Auto',
    description:
        'Use detected keyboard hardware; choose a type if detection is unavailable.',
  ),
  _PhysicalKeyboardFamilyOption(
    value: _kPhysicalKeyboardFamilyAnsi,
    label: 'ANSI',
    description: 'Common US-style keyboard.',
  ),
  _PhysicalKeyboardFamilyOption(
    value: _kPhysicalKeyboardFamilyIso,
    label: 'ISO',
    description: 'Common European-style keyboard.',
  ),
  _PhysicalKeyboardFamilyOption(
    value: _kPhysicalKeyboardFamilyJis,
    label: 'JIS',
    description:
        'Japanese keyboard, including remote Macs without an attached keyboard.',
  ),
];

String physicalKeyboardFamilyLabel(String value) => switch (value) {
  _kPhysicalKeyboardFamilyAnsi => 'ANSI',
  _kPhysicalKeyboardFamilyIso => 'ISO',
  _kPhysicalKeyboardFamilyJis => 'JIS',
  _ => 'Auto',
};

bool isPhysicalKeyboardFamilyChooserSupported(String peerPlatform) =>
    peerPlatform == kPeerPlatformMacOS && (isDesktop || isWebDesktop);

/// Kept for callers that still invoke the old automatic chooser hook.
void showKBLayoutTypeChooserIfNeeded(
  String peerPlatform,
  OverlayDialogManager dialogManager,
) {}

const _kPhysicalKeyboardFamilySessionInactive =
    'The remote session is no longer active.';
const _kPhysicalKeyboardFamilyUpdateFailed =
    'Could not update the physical keyboard type. Please try again.';

String _physicalKeyboardFamilyError(Object error, StackTrace stackTrace) {
  debugPrint('Physical keyboard family update failed (${error.runtimeType})');
  debugPrintStack(stackTrace: stackTrace);
  return translate(_kPhysicalKeyboardFamilyUpdateFailed);
}

Future<void> showPhysicalKeyboardFamilyChooser(FFI ffi) async {
  final sessionId = ffi.sessionId;
  if (!isPhysicalKeyboardFamilyChooserSupported(ffi.ffiModel.pi.platform) ||
      !ffi.acceptsKeyboardModeChanges) {
    return;
  }

  final dialogTag = '$sessionId-physical-keyboard-type';
  if (ffi.dialogManager.hasDialog(dialogTag)) return;

  final settings = SessionPeerSettingsRepository.forSession(sessionId);
  var selected = _kPhysicalKeyboardFamilyAuto;
  String? errorText;
  try {
    selected = await settings.readPeer(
      SessionPeerSettingsRegistry.physicalKeyboardFamily,
    );
  } catch (error, stackTrace) {
    errorText = _physicalKeyboardFamilyError(error, stackTrace);
  }
  if (ffi.sessionId != sessionId || !ffi.acceptsKeyboardModeChanges) return;

  var dialogActive = true;
  var busy = false;
  bool isDialogActive() =>
      dialogActive && ffi.dialogManager.hasDialog(dialogTag);
  bool isSessionActive() =>
      ffi.sessionId == sessionId && ffi.acceptsKeyboardModeChanges;

  try {
    await ffi.dialogManager.show<void>((setState, close, context) {
      void closeDialog([dynamic result]) {
        dialogActive = false;
        close(result);
      }

      Future<void> onChanged(String value) async {
        if (busy || !isDialogActive()) return;
        if (value == selected) return;
        if (!isSessionActive()) {
          errorText = translate(_kPhysicalKeyboardFamilySessionInactive);
          if (isDialogActive()) setState(() {});
          return;
        }
        busy = true;
        errorText = null;
        try {
          if (isDialogActive()) setState(() {});
          await ffi.inputModel.resetKeyboard(
            KeyboardResetReason.inputModeChange,
            invalidatePending: true,
            allowBlockedReleases: true,
          );
          if (!isDialogActive()) return;
          if (!isSessionActive()) {
            errorText = translate(_kPhysicalKeyboardFamilySessionInactive);
            return;
          }
          await settings.write(
            SessionPeerSettingsRegistry.physicalKeyboardFamily,
            value,
          );
          if (!isDialogActive()) return;
          if (!isSessionActive()) {
            errorText = translate(_kPhysicalKeyboardFamilySessionInactive);
            return;
          }
          selected = value;
        } catch (error, stackTrace) {
          if (isDialogActive()) {
            errorText = _physicalKeyboardFamilyError(error, stackTrace);
          }
        } finally {
          busy = false;
          if (isDialogActive()) setState(() {});
        }
      }

      final canChange = !busy && isSessionActive() && isDialogActive();
      return CustomAlertDialog(
        title: Text(translate('Physical keyboard type')),
        content: SizedBox(
          width: 480,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                translate(
                  'Choose the type of keyboard you use. This is saved for this computer and does not change its input language.',
                ),
              ),
              const SizedBox(height: 8),
              Text(
                translate(
                  'Install the latest RustAdmin on the remote Mac to use this setting.',
                ),
              ),
              const SizedBox(height: 12),
              if (busy)
                const Padding(
                  padding: EdgeInsets.only(bottom: 8),
                  child: LinearProgressIndicator(),
                ),
              if (errorText != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    errorText!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              ..._physicalKeyboardFamilyOptions.map(
                (option) => RadioListTile<String>(
                  key: ValueKey('physical-keyboard-family-${option.value}'),
                  value: option.value,
                  groupValue: selected,
                  title: Text(translate(option.label)),
                  subtitle: Text(translate(option.description)),
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  onChanged: canChange
                      ? (value) {
                          if (value != null) unawaited(onChanged(value));
                        }
                      : null,
                ),
              ),
            ],
          ),
        ),
        actions: [dialogButton('Close', onPressed: closeDialog)],
        onCancel: closeDialog,
      );
    }, tag: dialogTag);
  } catch (error, stackTrace) {
    dialogActive = false;
    _physicalKeyboardFamilyError(error, stackTrace);
  }
}
