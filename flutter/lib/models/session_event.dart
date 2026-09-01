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

final class SessionDisplayValue {
  const SessionDisplayValue({
    this.x,
    this.y,
    this.width,
    this.height,
    required this.cursorEmbedded,
    this.originalWidth,
    this.originalHeight,
    this.scaledWidth,
  });

  final double? x;
  final double? y;
  final int? width;
  final int? height;
  final bool cursorEmbedded;
  final int? originalWidth;
  final int? originalHeight;
  final int? scaledWidth;

  Map<String, Object> toLegacyMap() => {
    if (x != null) 'x': x!,
    if (y != null) 'y': y!,
    if (width != null) 'width': width!,
    if (height != null) 'height': height!,
    'cursor_embedded': cursorEmbedded ? 1 : 0,
    if (originalWidth != null) 'original_width': originalWidth!,
    if (originalHeight != null) 'original_height': originalHeight!,
    if (scaledWidth != null) 'scaled_width': scaledWidth!,
  };
}

final class SessionResolutionValue {
  const SessionResolutionValue(this.width, this.height);

  final int width;
  final int height;
}

final class SyncPeerInfoSessionEvent extends SessionEvent {
  SyncPeerInfoSessionEvent(List<SessionDisplayValue>? displays)
    : displays = displays == null
          ? null
          : List<SessionDisplayValue>.unmodifiable(displays);

  final List<SessionDisplayValue>? displays;
}

final class SwitchDisplaySessionEvent extends SessionEvent {
  SwitchDisplaySessionEvent({
    required this.displayIndex,
    required this.display,
    required List<SessionResolutionValue> resolutions,
  }) : resolutions = List<SessionResolutionValue>.unmodifiable(resolutions);

  final int displayIndex;
  final SessionDisplayValue display;
  final List<SessionResolutionValue> resolutions;
}

final class SyncPlatformAdditionsSessionEvent extends SessionEvent {
  SyncPlatformAdditionsSessionEvent({
    required this.clearVirtualDisplays,
    required Map<String, Object?> updates,
  }) : updates = Map<String, Object?>.unmodifiable(updates);

  final bool clearVirtualDisplays;
  final Map<String, Object?> updates;
}

final class SessionPeerFeaturesValue {
  const SessionPeerFeaturesValue({
    required this.privacyMode,
    required this.keyboardV2CommittedText,
    required this.keyboardV2PhysicalKey,
    required this.keyboardV2LayoutAwareText,
  });

  final bool privacyMode;
  final bool keyboardV2CommittedText;
  final bool keyboardV2PhysicalKey;
  final bool keyboardV2LayoutAwareText;

  Map<String, bool> toLegacyMap() => {
    'privacy_mode': privacyMode,
    'keyboard_v2_committed_text': keyboardV2CommittedText,
    'keyboard_v2_physical_key': keyboardV2PhysicalKey,
    'keyboard_v2_layout_aware_text': keyboardV2LayoutAwareText,
  };
}

final class PeerInfoSessionEvent extends SessionEvent {
  PeerInfoSessionEvent({
    required this.username,
    required this.hostname,
    required this.platform,
    required this.sasEnabled,
    required this.version,
    required this.currentDisplay,
    required List<SessionDisplayValue> displays,
    required this.features,
    required List<SessionResolutionValue> resolutions,
    required Map<String, Object?> platformAdditions,
  }) : displays = List<SessionDisplayValue>.unmodifiable(displays),
       resolutions = List<SessionResolutionValue>.unmodifiable(resolutions),
       platformAdditions = Map<String, Object?>.unmodifiable(platformAdditions);

  final String username;
  final String hostname;
  final String platform;
  final bool sasEnabled;
  final String version;
  final int currentDisplay;
  final List<SessionDisplayValue> displays;
  final SessionPeerFeaturesValue features;
  final List<SessionResolutionValue> resolutions;
  final Map<String, Object?> platformAdditions;

  Map<String, Object> toLegacyPayload({bool includeResolutions = true}) => {
    'name': 'peer_info',
    'username': username,
    'hostname': hostname,
    'platform': platform,
    'sas_enabled': sasEnabled.toString(),
    'displays': jsonEncode([
      for (final display in displays) display.toLegacyMap(),
    ]),
    'version': version,
    'features': jsonEncode(features.toLegacyMap()),
    'current_display': currentDisplay.toString(),
    if (includeResolutions)
      'resolutions': jsonEncode([
        for (final resolution in resolutions)
          {'width': resolution.width, 'height': resolution.height},
      ]),
    'platform_additions': jsonEncode(platformAdditions),
  };
}

enum TerminalResponseKind { opened, data, closed, error }

final class TerminalResponseSessionEvent extends SessionEvent {
  TerminalResponseSessionEvent({
    required this.kind,
    required this.terminalId,
    this.success = false,
    this.message = '',
    this.serviceId,
    List<int> persistentSessionIds = const [],
    List<int> data = const [],
    this.exitCode = 0,
  }) : persistentSessionIds = List<int>.unmodifiable(persistentSessionIds),
       data = List<int>.unmodifiable(data);

  final TerminalResponseKind kind;
  final int terminalId;
  final bool success;
  final String message;
  final String? serviceId;
  final List<int> persistentSessionIds;
  final List<int> data;
  final int exitCode;
}

const _qualityDisplayMapKeys = <String>{
  'fps',
  'decode_fps',
  'video_queue',
  'frame_resolution',
  'video_progress',
  'video_dropped',
  'video_decode_time_us',
  'video_render_submit_time_us',
  'video_feedback_queue',
  'display_refresh_millihz',
};

const _qualityScalarKeys = <String>{
  'connection_type',
  'speed',
  'delay',
  'target_bitrate',
  'codec_format',
  'chroma',
  'transport_mtu',
  'transport_rtt_ms',
  'transport_lost_packets',
  'datagram_payload',
  'negotiated_datagram_payload',
  'quic_protocol',
  'quic_video_transport',
  'quic_reassembly_drops',
  'quic_reassembly_reasons',
  'quic_reassembly_frame',
  'quic_reassembly_timing',
  'quic_keyframe_requests',
  'quic_keyframe_barrier',
  'quic_receiver_recovery',
  'quic_sender_recovery',
  'quic_sender_admission',
  'quic_sender_frame',
  'quic_sender_percentiles',
  'quic_sender_space',
  'quic_disposable_drops',
  'quic_video_queue_target_ms',
  'decoder',
  'renderer',
  'capture_backend',
  'capture_frame',
  'encoder_backend',
  'encoder_input',
  'video_threads',
  'texture_render',
  'direct',
  'fps_mode',
  'auto_fps',
  'video_delivery_phase',
  'video_recovery_count',
  'video_stall_ms',
  'requested_video_profile',
  'effective_video_profile',
  'movie_target_fps',
  'movie_pacing_fps',
  'movie_host_pipeline_p95_us',
  'movie_fallback_reason',
  'movie_playout_delay_ms',
};

final class QualityStatusSessionEvent extends SessionEvent {
  QualityStatusSessionEvent({
    required Map<String, String> values,
    required Map<String, Map<String, String>> displayMaps,
  }) : values = Map<String, String>.unmodifiable(values),
       displayMaps = Map<String, Map<String, String>>.unmodifiable({
         for (final entry in displayMaps.entries)
           entry.key: Map<String, String>.unmodifiable(entry.value),
       });

  final Map<String, String> values;
  final Map<String, Map<String, String>> displayMaps;

  bool contains(String key) =>
      values.containsKey(key) || displayMaps.containsKey(key);

  Map<String, String>? displayMap(String key) => displayMaps[key];
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
    case 'terminal_response':
      final terminalId = _decodeInt(event['terminal_id']);
      final type = event['type'];
      if (terminalId == null ||
          terminalId < 0 ||
          terminalId > 0x7fffffff ||
          type is! String) {
        return const InvalidSessionEvent(
          'terminal_response',
          'invalid terminal metadata',
        );
      }
      switch (type) {
        case 'opened':
          final success = event.containsKey('success')
              ? _decodeBool(event['success'])
              : false;
          final message = event['message'] ?? '';
          final serviceId = event['service_id'];
          final persistentIds = _decodeIntList(
            event['persistent_sessions'],
            maxLength: 256,
            missingIsEmpty: true,
          );
          if (success == null ||
              message is! String ||
              message.length > 64 * 1024 ||
              (serviceId != null &&
                  (serviceId is! String || serviceId.length > 4096)) ||
              persistentIds == null) {
            return const InvalidSessionEvent(
              'terminal_response',
              'invalid opened response',
            );
          }
          return TerminalResponseSessionEvent(
            kind: TerminalResponseKind.opened,
            terminalId: terminalId,
            success: success,
            message: message,
            serviceId: serviceId as String?,
            persistentSessionIds: persistentIds,
          );
        case 'data':
          final data = _decodeTerminalData(event['data']);
          return data == null
              ? const InvalidSessionEvent(
                  'terminal_response',
                  'invalid terminal data',
                )
              : TerminalResponseSessionEvent(
                  kind: TerminalResponseKind.data,
                  terminalId: terminalId,
                  data: data,
                );
        case 'closed':
          final exitCode = event.containsKey('exit_code')
              ? _decodeInt(event['exit_code'])
              : 0;
          return exitCode == null
              ? const InvalidSessionEvent(
                  'terminal_response',
                  'invalid exit code',
                )
              : TerminalResponseSessionEvent(
                  kind: TerminalResponseKind.closed,
                  terminalId: terminalId,
                  exitCode: exitCode,
                );
        case 'error':
          final message = event['message'] ?? 'Unknown error';
          return message is! String || message.length > 64 * 1024
              ? const InvalidSessionEvent(
                  'terminal_response',
                  'invalid error message',
                )
              : TerminalResponseSessionEvent(
                  kind: TerminalResponseKind.error,
                  terminalId: terminalId,
                  message: message,
                );
        default:
          return const InvalidSessionEvent(
            'terminal_response',
            'unknown response type',
          );
      }
    case 'peer_info':
      final username = _decodeBoundedString(event['username']);
      final hostname = _decodeBoundedString(event['hostname']);
      final platform = _decodeBoundedString(event['platform']);
      final version = _decodeBoundedString(event['version']);
      final sasEnabled = event.containsKey('sas_enabled')
          ? _decodeBool(event['sas_enabled'])
          : false;
      final currentDisplay = _decodeInt(event['current_display']);
      final displays = _decodeDisplays(event['displays']);
      final features = _decodePeerFeatures(event['features']);
      final resolutions = event.containsKey('resolutions')
          ? _decodeResolutions(event['resolutions'])
          : const <SessionResolutionValue>[];
      final additionsRaw = event['platform_additions'];
      final platformAdditions = additionsRaw == null || additionsRaw == ''
          ? const <String, Object?>{}
          : _decodeJsonObject(additionsRaw);
      if (username == null ||
          hostname == null ||
          platform == null ||
          version == null ||
          sasEnabled == null ||
          currentDisplay == null ||
          currentDisplay < -1 ||
          currentDisplay >= 64 ||
          displays == null ||
          features == null ||
          resolutions == null ||
          platformAdditions == null) {
        return const InvalidSessionEvent('peer_info', 'invalid snapshot');
      }
      return PeerInfoSessionEvent(
        username: username,
        hostname: hostname,
        platform: platform,
        sasEnabled: sasEnabled,
        version: version,
        currentDisplay: currentDisplay,
        displays: displays,
        features: features,
        resolutions: resolutions,
        platformAdditions: platformAdditions,
      );
    case 'sync_peer_info':
      if (!event.containsKey('displays')) {
        return SyncPeerInfoSessionEvent(null);
      }
      final displays = _decodeDisplays(event['displays']);
      return displays == null
          ? const InvalidSessionEvent('sync_peer_info', 'invalid displays')
          : SyncPeerInfoSessionEvent(displays);
    case 'switch_display':
      final displayIndex = _decodeInt(event['display']);
      final display = _decodeDisplay(event);
      final resolutions = _decodeResolutions(event['resolutions']);
      if (displayIndex == null ||
          displayIndex < 0 ||
          displayIndex >= 64 ||
          display == null ||
          resolutions == null) {
        return const InvalidSessionEvent(
          'switch_display',
          'invalid display payload',
        );
      }
      return SwitchDisplaySessionEvent(
        displayIndex: displayIndex,
        display: display,
        resolutions: resolutions,
      );
    case 'sync_platform_additions':
      final raw = event['platform_additions'];
      if (raw == '') {
        return SyncPlatformAdditionsSessionEvent(
          clearVirtualDisplays: true,
          updates: const {},
        );
      }
      final additions = _decodeJsonObject(raw);
      return additions == null
          ? const InvalidSessionEvent(
              'sync_platform_additions',
              'invalid platform additions',
            )
          : SyncPlatformAdditionsSessionEvent(
              clearVirtualDisplays: false,
              updates: additions,
            );
    case 'update_quality_status':
      final values = <String, String>{};
      final displayMaps = <String, Map<String, String>>{};
      for (final key in _qualityScalarKeys) {
        if (!event.containsKey(key)) continue;
        final value = event[key];
        if (value is! String || value.length > 1024 * 1024) {
          return InvalidSessionEvent('update_quality_status', 'invalid $key');
        }
        values[key] = value;
      }
      for (final key in _qualityDisplayMapKeys) {
        if (!event.containsKey(key)) continue;
        final value = event[key];
        if (value is! String || value.length > 1024 * 1024) {
          return InvalidSessionEvent('update_quality_status', 'invalid $key');
        }
        final decoded = _decodeStringMap(value);
        if (decoded == null) {
          return InvalidSessionEvent(
            'update_quality_status',
            'invalid $key map',
          );
        }
        displayMaps[key] = decoded;
      }
      return QualityStatusSessionEvent(
        values: values,
        displayMaps: displayMaps,
      );
    default:
      return null;
  }
}

int? _decodeInt(Object? value) {
  if (value is int) return value;
  if (value is num && value.isFinite && value == value.truncateToDouble()) {
    return value.toInt();
  }
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

String? _decodeBoundedString(Object? value) =>
    value is String && value.length <= 4096 ? value : null;

SessionPeerFeaturesValue? _decodePeerFeatures(Object? raw) {
  final values = _decodeJsonObject(raw);
  if (values == null) return null;
  const keys = <String>{
    'privacy_mode',
    'keyboard_v2_committed_text',
    'keyboard_v2_physical_key',
    'keyboard_v2_layout_aware_text',
  };
  for (final key in keys) {
    final value = values[key];
    if (value != null && value is! bool) return null;
  }
  return SessionPeerFeaturesValue(
    privacyMode: values['privacy_mode'] == true,
    keyboardV2CommittedText: values['keyboard_v2_committed_text'] == true,
    keyboardV2PhysicalKey: values['keyboard_v2_physical_key'] == true,
    keyboardV2LayoutAwareText: values['keyboard_v2_layout_aware_text'] == true,
  );
}

List<SessionDisplayValue>? _decodeDisplays(Object? raw) {
  final decoded = _decodeJsonInput(raw);
  if (decoded is! List || decoded.length > 64) return null;
  final displays = <SessionDisplayValue>[];
  for (final item in decoded) {
    final display = _decodeDisplay(item);
    if (display == null) return null;
    displays.add(display);
  }
  return displays;
}

SessionDisplayValue? _decodeDisplay(Object? raw) {
  if (raw is! Map) return null;
  final x = raw.containsKey('x') ? _decodeDouble(raw['x']) : null;
  final y = raw.containsKey('y') ? _decodeDouble(raw['y']) : null;
  final width = raw.containsKey('width') ? _decodeInt(raw['width']) : null;
  final height = raw.containsKey('height') ? _decodeInt(raw['height']) : null;
  final originalWidth = raw.containsKey('original_width')
      ? _decodeInt(raw['original_width'])
      : null;
  final originalHeight = raw.containsKey('original_height')
      ? _decodeInt(raw['original_height'])
      : null;
  final scaledWidth = raw.containsKey('scaled_width')
      ? _decodeInt(raw['scaled_width'])
      : null;
  if ((raw.containsKey('x') && x == null) ||
      (raw.containsKey('y') && y == null) ||
      (raw.containsKey('width') && width == null) ||
      (raw.containsKey('height') && height == null) ||
      (raw.containsKey('original_width') && originalWidth == null) ||
      (raw.containsKey('original_height') && originalHeight == null) ||
      (raw.containsKey('scaled_width') && scaledWidth == null)) {
    return null;
  }
  if ((x != null && x.abs() > 1000000000) ||
      (y != null && y.abs() > 1000000000) ||
      !_validDimension(width) ||
      !_validDimension(height) ||
      !_validOriginalDimension(originalWidth) ||
      !_validOriginalDimension(originalHeight) ||
      (scaledWidth != null && (scaledWidth < 0 || scaledWidth > 262144))) {
    return null;
  }
  final cursor = raw['cursor_embedded'];
  final cursorEmbedded = switch (cursor) {
    true => true,
    false || null => false,
    _ => _decodeInt(cursor) == 1,
  };
  return SessionDisplayValue(
    x: x,
    y: y,
    width: width,
    height: height,
    cursorEmbedded: cursorEmbedded,
    originalWidth: originalWidth,
    originalHeight: originalHeight,
    scaledWidth: scaledWidth,
  );
}

bool _validDimension(int? value) =>
    value == null || (value >= 0 && value <= 262144);

bool _validOriginalDimension(int? value) =>
    value == null || (value >= -1 && value <= 262144);

List<SessionResolutionValue>? _decodeResolutions(Object? raw) {
  var decoded = _decodeJsonInput(raw);
  if (decoded is Map) decoded = decoded['resolutions'];
  if (decoded is! List || decoded.length > 256) return null;
  final resolutions = <SessionResolutionValue>[];
  for (final item in decoded) {
    if (item is! Map) continue;
    final width = _decodeInt(item['width']);
    final height = _decodeInt(item['height']);
    if (width != null && width > 0 && height != null && height > 0) {
      resolutions.add(SessionResolutionValue(width, height));
    }
  }
  return resolutions;
}

Object? _decodeJsonInput(Object? raw) {
  if (raw is! String) return raw;
  if (raw.length > 1024 * 1024) return null;
  try {
    return jsonDecode(raw);
  } catch (_) {
    return null;
  }
}

Map<String, Object?>? _decodeJsonObject(Object? raw) {
  final decoded = _decodeJsonInput(raw);
  if (decoded is! Map) return null;
  final budget = _JsonBudget();
  final frozen = _freezeJsonValue(decoded, budget, 0);
  return identical(frozen, _invalidJson) || frozen is! Map<String, Object?>
      ? null
      : frozen;
}

const _invalidJson = Object();

final class _JsonBudget {
  int nodes = 0;
}

Object? _freezeJsonValue(Object? value, _JsonBudget budget, int depth) {
  if (depth > 8 || ++budget.nodes > 4096) return _invalidJson;
  if (value == null || value is bool || value is int) return value;
  if (value is double) return value.isFinite ? value : _invalidJson;
  if (value is String) {
    return value.length <= 64 * 1024 ? value : _invalidJson;
  }
  if (value is List) {
    final items = <Object?>[];
    for (final item in value) {
      final frozen = _freezeJsonValue(item, budget, depth + 1);
      if (identical(frozen, _invalidJson)) return _invalidJson;
      items.add(frozen);
    }
    return List<Object?>.unmodifiable(items);
  }
  if (value is Map) {
    final items = <String, Object?>{};
    for (final entry in value.entries) {
      final key = entry.key;
      if (key is! String || key.length > 4096) return _invalidJson;
      final frozen = _freezeJsonValue(entry.value, budget, depth + 1);
      if (identical(frozen, _invalidJson)) return _invalidJson;
      items[key] = frozen;
    }
    return Map<String, Object?>.unmodifiable(items);
  }
  return _invalidJson;
}

List<int>? _decodeIntList(
  Object? value, {
  required int maxLength,
  bool missingIsEmpty = false,
}) {
  if (value == null && missingIsEmpty) return const [];
  if (value is! List || value.length > maxLength) return null;
  final result = <int>[];
  for (final item in value) {
    final decoded = _decodeInt(item);
    if (decoded == null || decoded < 0 || decoded > 0x7fffffff) return null;
    result.add(decoded);
  }
  return result;
}

List<int>? _decodeTerminalData(Object? value) {
  const maxBytes = 1024 * 1024;
  if (value is String) {
    if (value.length > 2 * maxBytes) return null;
    try {
      final decoded = base64Decode(value);
      return decoded.length <= maxBytes ? decoded : null;
    } catch (_) {
      final decoded = utf8.encode(value);
      return decoded.length <= maxBytes ? decoded : null;
    }
  }
  if (value is! List || value.length > maxBytes) return null;
  final bytes = <int>[];
  for (final item in value) {
    if (item is! int || item < 0 || item > 255) return null;
    bytes.add(item);
  }
  return bytes;
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

Map<String, String>? _decodeStringMap(String value) {
  if (value.isEmpty) return const {};
  Object? decoded;
  try {
    decoded = jsonDecode(value);
  } catch (_) {
    return null;
  }
  if (decoded is! Map || decoded.length > 256) return null;
  final values = <String, String>{};
  for (final entry in decoded.entries) {
    final key = entry.key;
    final item = entry.value;
    if (key is! String) return null;
    if (item == null) continue;
    if (item is! String && item is! num && item is! bool) return null;
    final text = item.toString();
    if (text.length > 4096) return null;
    values[key] = text;
  }
  return values;
}
