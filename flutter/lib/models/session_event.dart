import 'dart:convert';

sealed class SessionEvent {
  const SessionEvent();
}

final class ConnectionReadySessionEvent extends SessionEvent {
  const ConnectionReadySessionEvent({
    required this.secure,
    required this.direct,
    required this.streamType,
  });

  final bool secure;
  final bool direct;
  final String streamType;
}

final class PermissionSessionEvent extends SessionEvent {
  PermissionSessionEvent(Map<String, bool> permissions)
    : permissions = Map.unmodifiable(permissions);

  final Map<String, bool> permissions;
}

final class ClipboardSessionEvent extends SessionEvent {
  const ClipboardSessionEvent(this.content);
  final String content;
}

final class ClientChatSessionEvent extends SessionEvent {
  const ClientChatSessionEvent(this.text);
  final String text;
}

final class ServerChatSessionEvent extends SessionEvent {
  const ServerChatSessionEvent({required this.id, required this.text});
  final int id;
  final String text;
}

final class ShowElevationSessionEvent extends SessionEvent {
  const ShowElevationSessionEvent(this.show);
  final bool show;
}

final class VoiceCallClosedSessionEvent extends SessionEvent {
  const VoiceCallClosedSessionEvent(this.reason);
  final String reason;
}

final class FingerprintSessionEvent extends SessionEvent {
  const FingerprintSessionEvent(this.fingerprint);
  final String fingerprint;
}

final class RecordStatusSessionEvent extends SessionEvent {
  const RecordStatusSessionEvent(this.start);
  final bool start;
}

enum SessionSignal {
  voiceCallWaiting,
  voiceCallStarted,
  voiceCallIncoming,
  exitRelativeMouseMode,
}

final class SessionSignalEvent extends SessionEvent {
  const SessionSignalEvent(this.signal);
  final SessionSignal signal;
}

final class CursorShapeSessionEvent extends SessionEvent {
  CursorShapeSessionEvent({
    required this.id,
    required this.hotx,
    required this.hoty,
    required this.width,
    required this.height,
    required List<int> colors,
  }) : colors = List.unmodifiable(colors);

  final String id;
  final double hotx;
  final double hoty;
  final int width;
  final int height;
  final List<int> colors;

  Map<String, dynamic> toLegacyPayload() => {
    'id': id,
    'hotx': hotx.toString(),
    'hoty': hoty.toString(),
    'width': width.toString(),
    'height': height.toString(),
    'colors': jsonEncode(colors),
  };
}

final class CursorIdSessionEvent extends SessionEvent {
  const CursorIdSessionEvent(this.id);
  final String id;

  Map<String, dynamic> toLegacyPayload() => {'id': id};
}

final class CursorPositionSessionEvent extends SessionEvent {
  const CursorPositionSessionEvent({required this.x, required this.y});
  final double x;
  final double y;
}

final class BlockInputSessionEvent extends SessionEvent {
  const BlockInputSessionEvent(this.enabled);
  final bool enabled;
}

final class PrivacyModeChangedSessionEvent extends SessionEvent {
  const PrivacyModeChangedSessionEvent();
}

final class TextureRenderSessionEvent extends SessionEvent {
  const TextureRenderSessionEvent(this.enabled);
  final bool enabled;
}

final class FollowCurrentDisplaySessionEvent extends SessionEvent {
  const FollowCurrentDisplaySessionEvent(this.displayIndex);
  final int? displayIndex;
}

final class InvalidSessionEvent extends SessionEvent {
  const InvalidSessionEvent(this.name, this.reason);

  final String name;
  final String reason;
}

SessionEvent? decodeTypedSessionEvent(Map<String, dynamic> event) {
  final name = event['name'];
  if (name is! String) return const InvalidSessionEvent('', 'missing name');
  switch (name) {
    case 'connection_ready':
      final secure = _decodeBool(event['secure']);
      final direct = _decodeBool(event['direct']);
      final streamType = event['stream_type'];
      if (secure == null || direct == null) {
        return const InvalidSessionEvent(
          'connection_ready',
          'invalid secure/direct flag',
        );
      }
      if (streamType != null && streamType is! String) {
        return const InvalidSessionEvent(
          'connection_ready',
          'invalid stream type',
        );
      }
      return ConnectionReadySessionEvent(
        secure: secure,
        direct: direct,
        streamType: streamType as String? ?? '',
      );
    case 'permission':
      final permissions = <String, bool>{};
      for (final entry in event.entries) {
        if (entry.key == 'name' || entry.key.isEmpty) continue;
        final value = _decodeBool(entry.value);
        if (value == null) {
          return InvalidSessionEvent('permission', 'invalid ${entry.key} flag');
        }
        permissions[entry.key] = value;
      }
      if (permissions.isEmpty) {
        return const InvalidSessionEvent('permission', 'empty snapshot');
      }
      return PermissionSessionEvent(permissions);
    case 'clipboard':
      final content = event['content'];
      return content is String
          ? ClipboardSessionEvent(content)
          : const InvalidSessionEvent('clipboard', 'invalid content');
    case 'chat_client_mode':
      final text = event['text'];
      return text == null || text is String
          ? ClientChatSessionEvent(text as String? ?? '')
          : const InvalidSessionEvent('chat_client_mode', 'invalid text');
    case 'chat_server_mode':
      final id = _decodeInt(event['id']);
      final text = event['text'];
      if (id == null || (text != null && text is! String)) {
        return const InvalidSessionEvent('chat_server_mode', 'invalid id/text');
      }
      return ServerChatSessionEvent(id: id, text: text as String? ?? '');
    case 'show_elevation':
      return ShowElevationSessionEvent(event['show'].toString() == 'true');
    case 'on_voice_call_closed':
      return VoiceCallClosedSessionEvent(event['reason'].toString());
    case 'fingerprint':
      final fingerprint = event['fingerprint'];
      return fingerprint == null || fingerprint is String
          ? FingerprintSessionEvent(fingerprint as String? ?? '')
          : const InvalidSessionEvent('fingerprint', 'invalid value');
    case 'record_status':
      final start = _decodeBool(event['start']);
      return start == null
          ? const InvalidSessionEvent('record_status', 'invalid start flag')
          : RecordStatusSessionEvent(start);
    case 'on_voice_call_waiting':
      return const SessionSignalEvent(SessionSignal.voiceCallWaiting);
    case 'on_voice_call_started':
      return const SessionSignalEvent(SessionSignal.voiceCallStarted);
    case 'on_voice_call_incoming':
      return const SessionSignalEvent(SessionSignal.voiceCallIncoming);
    case 'exit_relative_mouse_mode':
      return const SessionSignalEvent(SessionSignal.exitRelativeMouseMode);
    case 'cursor_data':
      final id = _decodeNonEmptyString(event['id']);
      final hotx = _decodeDouble(event['hotx']);
      final hoty = _decodeDouble(event['hoty']);
      final width = _decodeInt(event['width']);
      final height = _decodeInt(event['height']);
      if (id == null ||
          hotx == null ||
          hoty == null ||
          width == null ||
          height == null ||
          width <= 0 ||
          height <= 0 ||
          width > 4096 ||
          height > 4096) {
        return const InvalidSessionEvent('cursor_data', 'invalid metadata');
      }
      final expectedBytes = width * height * 4;
      if (expectedBytes > 16 * 1024 * 1024) {
        return const InvalidSessionEvent('cursor_data', 'payload too large');
      }
      final colors = _decodeByteList(event['colors'], expectedBytes);
      return colors == null
          ? const InvalidSessionEvent('cursor_data', 'invalid colors')
          : CursorShapeSessionEvent(
              id: id,
              hotx: hotx,
              hoty: hoty,
              width: width,
              height: height,
              colors: colors,
            );
    case 'cursor_id':
      final id = _decodeNonEmptyString(event['id']);
      return id == null
          ? const InvalidSessionEvent('cursor_id', 'invalid id')
          : CursorIdSessionEvent(id);
    case 'cursor_position':
      final x = _decodeDouble(event['x']);
      final y = _decodeDouble(event['y']);
      return x == null || y == null
          ? const InvalidSessionEvent('cursor_position', 'invalid position')
          : CursorPositionSessionEvent(x: x, y: y);
    case 'update_block_input_state':
      final state = event['input_state'];
      return state is! String
          ? const InvalidSessionEvent(
              'update_block_input_state',
              'invalid state',
            )
          : BlockInputSessionEvent(state == 'on');
    case 'update_privacy_mode':
      return const PrivacyModeChangedSessionEvent();
    case 'use_texture_render':
      final value = event['v'];
      return value is! String
          ? const InvalidSessionEvent('use_texture_render', 'invalid value')
          : TextureRenderSessionEvent(value == 'Y');
    case 'follow_current_display':
      if (!event.containsKey('display_idx')) {
        return const FollowCurrentDisplaySessionEvent(null);
      }
      final displayIndex = _decodeInt(event['display_idx']);
      return displayIndex == null
          ? const InvalidSessionEvent(
              'follow_current_display',
              'invalid display index',
            )
          : FollowCurrentDisplaySessionEvent(displayIndex);
    default:
      return null;
  }
}

int? _decodeInt(Object? value) {
  if (value is int) return value;
  if (value is String) return int.tryParse(value);
  return null;
}

bool? _decodeBool(Object? value) {
  if (value is bool) return value;
  if (value is String) {
    if (value.toLowerCase() == 'true') return true;
    if (value.toLowerCase() == 'false') return false;
  }
  return null;
}

double? _decodeDouble(Object? value) {
  final decoded = switch (value) {
    num number => number.toDouble(),
    String text => double.tryParse(text),
    _ => null,
  };
  return decoded?.isFinite == true ? decoded : null;
}

String? _decodeNonEmptyString(Object? value) {
  if (value == null) return null;
  final decoded = value.toString();
  return decoded.isEmpty ? null : decoded;
}

List<int>? _decodeByteList(Object? value, int expectedLength) {
  if (value is! String) return null;
  Object? decoded;
  try {
    decoded = jsonDecode(value);
  } catch (_) {
    return null;
  }
  if (decoded is! List || decoded.length != expectedLength) return null;
  final bytes = <int>[];
  for (final item in decoded) {
    if (item is! int || item < 0 || item > 255) return null;
    bytes.add(item);
  }
  return bytes;
}
