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

final class FileJobProgressSessionEvent extends SessionEvent {
  const FileJobProgressSessionEvent({
    required this.id,
    required this.fileNum,
    required this.speed,
    required this.finishedSize,
  });

  final int id;
  final int fileNum;
  final double speed;
  final int finishedSize;
}

sealed class FileJobResultSessionEvent extends SessionEvent {
  const FileJobResultSessionEvent({required this.id, required this.fileNum});

  final int id;
  final int fileNum;
}

final class FileJobDoneSessionEvent extends FileJobResultSessionEvent {
  const FileJobDoneSessionEvent({
    required super.id,
    required super.fileNum,
    required this.speed,
  });

  final double speed;
}

final class FileJobErrorSessionEvent extends FileJobResultSessionEvent {
  const FileJobErrorSessionEvent({
    required super.id,
    required super.fileNum,
    required this.error,
  });

  final String error;
}

final class FileFolderStatsSessionEvent extends SessionEvent {
  const FileFolderStatsSessionEvent({
    required this.id,
    required this.entryCount,
    required this.totalSize,
  });

  final int id;
  final int entryCount;
  final double totalSize;
}

final class SessionFileEntryValue {
  const SessionFileEntryValue({
    required this.entryType,
    required this.modifiedTime,
    required this.name,
    required this.size,
  });

  final int entryType;
  final int modifiedTime;
  final String name;
  final int size;
}

final class SessionFileDirectoryValue {
  SessionFileDirectoryValue({
    required this.id,
    required this.path,
    required List<SessionFileEntryValue> entries,
  }) : entries = List<SessionFileEntryValue>.unmodifiable(entries);

  final int id;
  final String path;
  final List<SessionFileEntryValue> entries;
}

final class FileDirectorySessionEvent extends SessionEvent {
  const FileDirectorySessionEvent({
    required this.isLocal,
    required this.directory,
  });

  final bool isLocal;
  final SessionFileDirectoryValue directory;
}

final class EmptyDirectoriesSessionEvent extends SessionEvent {
  EmptyDirectoriesSessionEvent({
    required this.isLocal,
    required this.path,
    required List<SessionFileDirectoryValue> directories,
  }) : directories = List<SessionFileDirectoryValue>.unmodifiable(directories);

  final bool isLocal;
  final String path;
  final List<SessionFileDirectoryValue> directories;
}

final class FileOverrideConfirmSessionEvent extends SessionEvent {
  const FileOverrideConfirmSessionEvent({
    required this.id,
    required this.fileNum,
    required this.readPath,
    required this.isUpload,
    required this.isIdentical,
  });

  final int id;
  final int fileNum;
  final String readPath;
  final bool isUpload;
  final bool isIdentical;
}

final class FileResumeJobSessionEvent extends SessionEvent {
  const FileResumeJobSessionEvent({
    required this.remotePath,
    required this.localPath,
    required this.showHidden,
    required this.fileNum,
    required this.isRemote,
    required this.autoStart,
    required this.id,
  });

  final String remotePath;
  final String localPath;
  final bool showHidden;
  final int fileNum;
  final bool isRemote;
  final bool autoStart;
  final int? id;
}

enum SessionControlKind {
  cancelMessageBox,
  switchBack,
  portableServiceRunning,
  urlSchemeReceived,
}

final class SessionControlEvent extends SessionEvent {
  const SessionControlEvent({
    required this.kind,
    this.value = '',
    this.enabled = false,
  });

  final SessionControlKind kind;
  final String value;
  final bool enabled;
}

final class PeerHashSyncSessionEvent extends SessionEvent {
  const PeerHashSyncSessionEvent({required this.id, required this.hash});

  final String id;
  final String hash;
}

enum PeerOptionSyncKind { viewOnly, keyboardMode, inputSource, other }

final class PeerOptionSyncSessionEvent extends SessionEvent {
  const PeerOptionSyncSessionEvent({required this.kind, this.viewOnly});

  final PeerOptionSyncKind kind;
  final bool? viewOnly;
}

final class WebSelectedFileSessionEvent extends SessionEvent {
  const WebSelectedFileSessionEvent({
    required this.handleIndex,
    required this.file,
  });

  final int handleIndex;
  final SessionFileEntryValue file;
}

final class WebEmptyDirectoriesSessionEvent extends SessionEvent {
  WebEmptyDirectoriesSessionEvent(List<String> directories)
    : directories = List<String>.unmodifiable(directories);

  final List<String> directories;
}

final class PrinterRequestSessionEvent extends SessionEvent {
  const PrinterRequestSessionEvent({required this.id, required this.path});

  final int id;
  final String path;
}

final class ScreenshotSessionEvent extends SessionEvent {
  const ScreenshotSessionEvent(this.message);

  final String message;
}

enum MessageBoxOrigin { core, plugin }

final class SecurityPromptDetails {
  const SecurityPromptDetails({
    required this.peer,
    required this.peerId,
    required this.direct,
    this.fingerprint = '',
    this.trustPhrase = '',
  });

  final String peer;
  final String peerId;
  final bool direct;
  final String fingerprint;
  final String trustPhrase;
}

final class MessageBoxSessionEvent extends SessionEvent {
  const MessageBoxSessionEvent({
    required this.type,
    required this.title,
    required this.text,
    required this.link,
    required this.hasRetry,
    required this.origin,
    this.securityDetails,
  });

  final String type;
  final String title;
  final String text;
  final String link;
  final bool hasRetry;
  final MessageBoxOrigin origin;
  final SecurityPromptDetails? securityDetails;
}

final class ToastSessionEvent extends SessionEvent {
  const ToastSessionEvent({
    required this.type,
    required this.text,
    required this.durationMs,
  });

  final String type;
  final String text;
  final int durationMs;
}

final class WindowsSessionValue {
  const WindowsSessionValue({required this.id, required this.name});

  final String id;
  final String name;
}

final class MultipleWindowsSessionsEvent extends SessionEvent {
  MultipleWindowsSessionsEvent(List<WindowsSessionValue> sessions)
    : sessions = List<WindowsSessionValue>.unmodifiable(sessions);

  final List<WindowsSessionValue> sessions;
}

final class SessionClientValue {
  const SessionClientValue({
    required this.id,
    required this.authorized,
    required this.isFileTransfer,
    required this.isViewCamera,
    required this.isTerminal,
    required this.portForward,
    required this.name,
    required this.avatar,
    required this.peerId,
    required this.keyboard,
    required this.clipboard,
    required this.audio,
    required this.file,
    required this.restart,
    required this.recording,
    required this.blockInput,
    required this.disconnected,
    required this.fromSwitch,
    required this.inVoiceCall,
    required this.incomingVoiceCall,
  });

  final int id;
  final bool authorized;
  final bool isFileTransfer;
  final bool isViewCamera;
  final bool isTerminal;
  final String portForward;
  final String name;
  final String avatar;
  final String peerId;
  final bool keyboard;
  final bool clipboard;
  final bool audio;
  final bool file;
  final bool restart;
  final bool recording;
  final bool blockInput;
  final bool disconnected;
  final bool fromSwitch;
  final bool inVoiceCall;
  final bool incomingVoiceCall;
}

enum ClientSnapshotKind { addConnection, voiceState }

final class ClientSnapshotSessionEvent extends SessionEvent {
  const ClientSnapshotSessionEvent({required this.kind, required this.client});

  final ClientSnapshotKind kind;
  final SessionClientValue client;
}

final class ClientRemovedSessionEvent extends SessionEvent {
  const ClientRemovedSessionEvent({required this.id, required this.close});

  final int id;
  final bool close;
}

enum ClientPermissionKind { update, request }

final class ClientPermissionSessionEvent extends SessionEvent {
  const ClientPermissionSessionEvent({
    required this.kind,
    required this.clientId,
    required this.name,
    required this.enabled,
    this.requestId = '',
  });

  final ClientPermissionKind kind;
  final int clientId;
  final String requestId;
  final String name;
  final bool enabled;
}

final class SessionPluginCatalogValue {
  const SessionPluginCatalogValue({
    required this.sourceName,
    required this.sourceUrl,
    required this.sourceDescription,
    required this.id,
    required this.name,
    required this.version,
    required this.description,
    required this.author,
    required this.home,
    required this.license,
    required this.source,
    required this.lastReleased,
    required this.published,
    required this.installedVersion,
    required this.invalidReason,
  });

  final String sourceName;
  final String sourceUrl;
  final String sourceDescription;
  final String id;
  final String name;
  final String version;
  final String description;
  final String author;
  final String home;
  final String license;
  final String source;
  final DateTime lastReleased;
  final DateTime published;
  final String installedVersion;
  final String invalidReason;
}

final class PluginCatalogSessionEvent extends SessionEvent {
  PluginCatalogSessionEvent(List<SessionPluginCatalogValue> plugins)
    : plugins = List<SessionPluginCatalogValue>.unmodifiable(plugins);

  final List<SessionPluginCatalogValue> plugins;
}

final class PluginInstallStatusSessionEvent extends SessionEvent {
  const PluginInstallStatusSessionEvent({
    required this.id,
    required this.message,
    required this.install,
  });

  final String id;
  final String message;
  final bool install;
}

final class PluginContentSessionEvent extends SessionEvent {
  const PluginContentSessionEvent(this.message);

  final MessageBoxSessionEvent? message;
}

enum SessionPluginUiKind { button, checkbox }

final class SessionPluginUiValue {
  const SessionPluginUiValue({
    required this.kind,
    required this.key,
    required this.text,
    required this.tooltip,
    required this.action,
    this.icon = '',
  });

  final SessionPluginUiKind kind;
  final String key;
  final String text;
  final String tooltip;
  final String action;
  final String icon;
}

final class PluginReloadSessionEvent extends SessionEvent {
  PluginReloadSessionEvent({
    required this.id,
    required this.location,
    required List<SessionPluginUiValue> ui,
  }) : ui = List<SessionPluginUiValue>.unmodifiable(ui);

  final String id;
  final String location;
  final List<SessionPluginUiValue> ui;
}

final class PluginOptionSessionEvent extends SessionEvent {
  const PluginOptionSessionEvent({
    required this.location,
    required this.id,
    required this.peer,
    required this.key,
    required this.value,
  });

  final String location;
  final String id;
  final String peer;
  final String key;
  final String value;
}

final class SessionCmTransferJobValue {
  const SessionCmTransferJobValue({
    required this.connectionId,
    required this.id,
    required this.path,
    required this.isRemote,
    required this.totalSize,
    required this.finishedSize,
    required this.transferred,
    required this.done,
    required this.cancel,
    required this.error,
  });

  final int connectionId;
  final int id;
  final String path;
  final bool isRemote;
  final int totalSize;
  final int finishedSize;
  final int transferred;
  final bool done;
  final bool cancel;
  final String error;
}

final class CmTransferLogSessionEvent extends SessionEvent {
  CmTransferLogSessionEvent(List<SessionCmTransferJobValue> jobs)
    : jobs = List<SessionCmTransferJobValue>.unmodifiable(jobs);

  final List<SessionCmTransferJobValue> jobs;
}

enum CmFileActionKind { remove, createDirectory }

final class CmFileActionSessionEvent extends SessionEvent {
  const CmFileActionSessionEvent({
    required this.kind,
    required this.connectionId,
    required this.id,
    required this.path,
    required this.directory,
  });

  final CmFileActionKind kind;
  final int connectionId;
  final int id;
  final String path;
  final bool directory;
}

final class CmFileRenameSessionEvent extends SessionEvent {
  const CmFileRenameSessionEvent({
    required this.connectionId,
    required this.path,
    required this.newName,
  });

  final int connectionId;
  final String path;
  final String newName;
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
    case 'msgbox':
      return decodeMessageBoxSessionEvent(event);
    case 'toast':
      final type = event['type'] ?? 'info';
      final text = event['text'] ?? '';
      final durationMs = event.containsKey('dur_msec')
          ? _decodeInt(event['dur_msec'])
          : 2000;
      return type is! String ||
              type.length > 4096 ||
              text is! String ||
              text.length > 1024 * 1024 ||
              durationMs == null ||
              durationMs < 0 ||
              durationMs > 10 * 60 * 1000
          ? const InvalidSessionEvent('toast', 'invalid payload')
          : ToastSessionEvent(type: type, text: text, durationMs: durationMs);
    case 'set_multiple_windows_session':
      final sessions = _decodeWindowsSessions(event['windows_sessions']);
      return sessions == null || sessions.isEmpty
          ? const InvalidSessionEvent(
              'set_multiple_windows_session',
              'invalid sessions',
            )
          : MultipleWindowsSessionsEvent(sessions);
    case 'add_connection':
    case 'update_voice_call_state':
      final client = _decodeClientValue(event['client']);
      return client == null
          ? InvalidSessionEvent(name, 'invalid client snapshot')
          : ClientSnapshotSessionEvent(
              kind: name == 'add_connection'
                  ? ClientSnapshotKind.addConnection
                  : ClientSnapshotKind.voiceState,
              client: client,
            );
    case 'on_client_remove':
      final id = _decodeInt(event['id']);
      final close = _decodeBool(event['close']);
      return id == null || id < 0 || close == null
          ? const InvalidSessionEvent(
              'on_client_remove',
              'invalid client state',
            )
          : ClientRemovedSessionEvent(id: id, close: close);
    case 'permission_update':
    case 'permission_request':
      final id = _decodeInt(event['id']);
      final permissionName = event['permission_name'];
      final enabled = _decodeBool(event['enabled']);
      final requestId = name == 'permission_request'
          ? _decodeNonEmptyString(event['request_id'])
          : '';
      return id == null ||
              id < 0 ||
              permissionName is! String ||
              permissionName.isEmpty ||
              permissionName.length > 4096 ||
              enabled == null ||
              (name == 'permission_request' &&
                  (requestId == null || requestId.length > 64))
          ? InvalidSessionEvent(name, 'invalid permission')
          : ClientPermissionSessionEvent(
              kind: name == 'permission_update'
                  ? ClientPermissionKind.update
                  : ClientPermissionKind.request,
              clientId: id,
              requestId: requestId ?? '',
              name: permissionName,
              enabled: enabled,
            );
    case 'plugin_manager':
      return _decodePluginManagerEvent(event);
    case 'plugin_event':
      final content = _decodeJsonObject(event['content']);
      if (content == null) {
        return const InvalidSessionEvent('plugin_event', 'invalid content');
      }
      if (content['t'] != 'MsgBox') {
        return const PluginContentSessionEvent(null);
      }
      final payload = content['c'];
      if (payload is! Map<String, Object?>) {
        return const InvalidSessionEvent('plugin_event', 'invalid message box');
      }
      final message = decodeMessageBoxSessionEvent(
        Map<String, dynamic>.from(payload),
        origin: MessageBoxOrigin.plugin,
      );
      return message is MessageBoxSessionEvent
          ? PluginContentSessionEvent(message)
          : const InvalidSessionEvent(
              'plugin_event',
              'invalid message box payload',
            );
    case 'plugin_reload':
      final id = _decodeBoundedString(event['id']);
      final location = _decodeBoundedString(event['location']);
      final ui = _decodePluginUi(event['ui']);
      return id == null ||
              id.isEmpty ||
              location == null ||
              location.isEmpty ||
              ui == null
          ? const InvalidSessionEvent('plugin_reload', 'invalid UI payload')
          : PluginReloadSessionEvent(id: id, location: location, ui: ui);
    case 'plugin_option':
      final location = _decodeBoundedString(event['location']);
      final id = _decodeBoundedString(event['id']);
      final peer = event['peer'] ?? '';
      final key = _decodeBoundedString(event['key']);
      final value = event['value'];
      return location == null ||
              location.isEmpty ||
              id == null ||
              id.isEmpty ||
              peer is! String ||
              peer.length > 4096 ||
              key == null ||
              key.isEmpty ||
              value is! String ||
              value.length > 64 * 1024
          ? const InvalidSessionEvent('plugin_option', 'invalid option payload')
          : PluginOptionSessionEvent(
              location: location,
              id: id,
              peer: peer,
              key: key,
              value: value,
            );
    case 'cm_file_transfer_log':
      return _decodeCmFileLogEvent(event);
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
    case 'job_progress':
      final id = _decodeInt(event['id']);
      final fileNum = _decodeInt(event['file_num']);
      final speed = _decodeDouble(event['speed']);
      final finishedSize = _decodeInt(event['finished_size']);
      return id == null ||
              id < 0 ||
              fileNum == null ||
              fileNum < 0 ||
              speed == null ||
              speed < 0 ||
              finishedSize == null ||
              finishedSize < 0
          ? const InvalidSessionEvent('job_progress', 'invalid progress')
          : FileJobProgressSessionEvent(
              id: id,
              fileNum: fileNum,
              speed: speed,
              finishedSize: finishedSize,
            );
    case 'job_done':
      final id = _decodeInt(event['id']);
      final fileNum = event.containsKey('file_num')
          ? _decodeInt(event['file_num'])
          : 0;
      final speed = event.containsKey('speed')
          ? _decodeDouble(event['speed'])
          : 0.0;
      return id == null ||
              id < 0 ||
              fileNum == null ||
              fileNum < 0 ||
              speed == null ||
              speed < 0
          ? const InvalidSessionEvent('job_done', 'invalid result')
          : FileJobDoneSessionEvent(id: id, fileNum: fileNum, speed: speed);
    case 'job_error':
      final id = _decodeInt(event['id']);
      final fileNum = event.containsKey('file_num')
          ? _decodeInt(event['file_num'])
          : 0;
      final error = event['err'];
      return id == null ||
              id < 0 ||
              fileNum == null ||
              fileNum < 0 ||
              error is! String ||
              error.length > 64 * 1024
          ? const InvalidSessionEvent('job_error', 'invalid result')
          : FileJobErrorSessionEvent(id: id, fileNum: fileNum, error: error);
    case 'update_folder_files':
      final info = _decodeJsonObject(event['info']);
      final id = _decodeInt(info?['id']);
      final entryCount = _decodeInt(info?['num_entries']);
      final totalSize = _decodeDouble(info?['total_size']);
      return id == null ||
              id < 0 ||
              entryCount == null ||
              entryCount < 0 ||
              totalSize == null ||
              totalSize < 0
          ? const InvalidSessionEvent(
              'update_folder_files',
              'invalid folder stats',
            )
          : FileFolderStatsSessionEvent(
              id: id,
              entryCount: entryCount,
              totalSize: totalSize,
            );
    case 'file_dir':
      final isLocal = _decodeBool(event['is_local']);
      final directory = _decodeFileDirectoryPayload(event['value']);
      return isLocal == null || directory == null
          ? const InvalidSessionEvent('file_dir', 'invalid directory')
          : FileDirectorySessionEvent(isLocal: isLocal, directory: directory);
    case 'empty_dirs':
      final isLocal = _decodeBool(event['is_local']);
      final payload = _decodeEmptyDirectoriesPayload(event['value']);
      return isLocal == null || payload == null
          ? const InvalidSessionEvent('empty_dirs', 'invalid directory list')
          : EmptyDirectoriesSessionEvent(
              isLocal: isLocal,
              path: payload.path,
              directories: payload.directories,
            );
    case 'override_file_confirm':
      final id = _decodeInt(event['id']);
      final fileNum = _decodeInt(event['file_num']);
      final readPath = event['read_path'];
      final isUpload = _decodeBool(event['is_upload']);
      final isIdentical = _decodeBool(event['is_identical']);
      return id == null ||
              id < 0 ||
              fileNum == null ||
              fileNum < 0 ||
              readPath is! String ||
              readPath.length > 32 * 1024 ||
              isUpload == null ||
              isIdentical == null
          ? const InvalidSessionEvent(
              'override_file_confirm',
              'invalid conflict',
            )
          : FileOverrideConfirmSessionEvent(
              id: id,
              fileNum: fileNum,
              readPath: readPath,
              isUpload: isUpload,
              isIdentical: isIdentical,
            );
    case 'load_last_job':
      final value = _decodeJsonInput(event['value']);
      if (value is! Map) {
        return const InvalidSessionEvent('load_last_job', 'invalid snapshot');
      }
      final remotePath = value['remote'];
      final localPath = value['to'];
      final showHidden = value['show_hidden'];
      final fileNum = _decodeInt(value['file_num']);
      final isRemote = value['is_remote'];
      final autoStart = value['auto_start'] == true;
      final decodedId = _decodeInt(value['id']);
      final id = decodedId != null && decodedId >= 0 ? decodedId : null;
      return remotePath is! String ||
              remotePath.length > 32 * 1024 ||
              localPath is! String ||
              localPath.length > 32 * 1024 ||
              showHidden is! bool ||
              fileNum == null ||
              fileNum < 0 ||
              isRemote is! bool
          ? const InvalidSessionEvent(
              'load_last_job',
              'invalid snapshot fields',
            )
          : FileResumeJobSessionEvent(
              remotePath: remotePath,
              localPath: localPath,
              showHidden: showHidden,
              fileNum: fileNum,
              isRemote: isRemote,
              autoStart: autoStart && id != null,
              id: id,
            );
    case 'cancel_msgbox':
      final tag = event['tag'];
      return tag is! String || tag.length > 4096
          ? const InvalidSessionEvent('cancel_msgbox', 'invalid tag')
          : SessionControlEvent(
              kind: SessionControlKind.cancelMessageBox,
              value: tag,
            );
    case 'switch_back':
      final peerId = _decodeBoundedString(event['peer_id']);
      return peerId == null || peerId.isEmpty
          ? const InvalidSessionEvent('switch_back', 'invalid peer id')
          : SessionControlEvent(
              kind: SessionControlKind.switchBack,
              value: peerId,
            );
    case 'portable_service_running':
      final running = _decodeBool(event['running']);
      return running == null
          ? const InvalidSessionEvent(
              'portable_service_running',
              'invalid state',
            )
          : SessionControlEvent(
              kind: SessionControlKind.portableServiceRunning,
              enabled: running,
            );
    case 'on_url_scheme_received':
      final url = event['url'];
      return url is! String || url.length > 64 * 1024
          ? const InvalidSessionEvent('on_url_scheme_received', 'invalid URL')
          : SessionControlEvent(
              kind: SessionControlKind.urlSchemeReceived,
              value: url,
            );
    case 'sync_peer_hash_password_to_personal_ab':
      final id = _decodeBoundedString(event['id']);
      final hash = event['hash'];
      return id == null ||
              id.isEmpty ||
              hash is! String ||
              hash.length > 64 * 1024
          ? const InvalidSessionEvent(
              'sync_peer_hash_password_to_personal_ab',
              'invalid peer/hash',
            )
          : PeerHashSyncSessionEvent(id: id, hash: hash);
    case 'sync_peer_option':
      final key = event['k'];
      if (key is! String || key.length > 4096) {
        return const InvalidSessionEvent(
          'sync_peer_option',
          'invalid option key',
        );
      }
      if (key == 'view-only') {
        final value = _decodeBool(event['v']);
        return value == null
            ? const InvalidSessionEvent(
                'sync_peer_option',
                'invalid view-only value',
              )
            : PeerOptionSyncSessionEvent(
                kind: PeerOptionSyncKind.viewOnly,
                viewOnly: value,
              );
      }
      return PeerOptionSyncSessionEvent(
        kind: switch (key) {
          'keyboard_mode' => PeerOptionSyncKind.keyboardMode,
          'input_source' => PeerOptionSyncKind.inputSource,
          _ => PeerOptionSyncKind.other,
        },
      );
    case 'selected_files':
      final handleIndex = _decodeInt(event['handleIndex']);
      final file = _decodeFileEntry(_decodeJsonInput(event['file']));
      return handleIndex == null || handleIndex < 0 || file == null
          ? const InvalidSessionEvent('selected_files', 'invalid file')
          : WebSelectedFileSessionEvent(handleIndex: handleIndex, file: file);
    case 'send_emptry_dirs':
      final values = _decodeJsonInput(event['dirs'], maxBytes: 8 * 1024 * 1024);
      if (values is! List || values.length > 65536) {
        return const InvalidSessionEvent(
          'send_emptry_dirs',
          'invalid directories',
        );
      }
      final directories = <String>[];
      for (final value in values) {
        if (value is! String || value.length > 32 * 1024) {
          return const InvalidSessionEvent(
            'send_emptry_dirs',
            'invalid directory path',
          );
        }
        directories.add(value);
      }
      return WebEmptyDirectoriesSessionEvent(directories);
    case 'printer_request':
      final id = _decodeInt(event['id']);
      final path = event['path'];
      return id == null || id < 0 || path is! String || path.length > 32 * 1024
          ? const InvalidSessionEvent('printer_request', 'invalid job')
          : PrinterRequestSessionEvent(id: id, path: path);
    case 'screenshot':
      final message = event['msg'] ?? '';
      return message is! String || message.length > 64 * 1024
          ? const InvalidSessionEvent('screenshot', 'invalid message')
          : ScreenshotSessionEvent(message);
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

SessionEvent decodeMessageBoxSessionEvent(
  Map<String, dynamic> event, {
  MessageBoxOrigin origin = MessageBoxOrigin.core,
}) {
  final type = event['type'];
  final title = event['title'];
  final text = event['text'];
  final link = event['link'] ?? '';
  if (type is! String ||
      type.length > 4096 ||
      title is! String ||
      title.length > 64 * 1024 ||
      text is! String ||
      text.length > 1024 * 1024 ||
      link is! String ||
      link.length > 64 * 1024) {
    return const InvalidSessionEvent('msgbox', 'invalid payload');
  }
  SecurityPromptDetails? securityDetails;
  if (origin == MessageBoxOrigin.core &&
      (type == 'input-pairing-passphrase' ||
          type == 'input-direct-pairing-passphrase' ||
          type == 'confirm-peer-trust' ||
          type == 'confirm-direct-trust')) {
    securityDetails = _decodeSecurityPromptDetails(
      text,
      trust: type == 'confirm-peer-trust' || type == 'confirm-direct-trust',
    );
  }
  return MessageBoxSessionEvent(
    type: type,
    title: title,
    text: text,
    link: link,
    hasRetry:
        origin == MessageBoxOrigin.core &&
        event['hasRetry'].toString() == 'true',
    origin: origin,
    securityDetails: securityDetails,
  );
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

SecurityPromptDetails? _decodeSecurityPromptDetails(
  String raw, {
  required bool trust,
}) {
  final values = _decodeJsonObject(raw);
  if (values == null) return null;
  final peer = values['peer'];
  final peerId = values['peer_id'];
  final direct = values['direct'];
  final fingerprint = values['fingerprint'] ?? '';
  final trustPhrase = values['trust_phrase'] ?? '';
  if (peer is! String ||
      peer.isEmpty ||
      peer.length > 4096 ||
      peerId is! String ||
      peerId.isEmpty ||
      peerId.length > 4096 ||
      (direct != null && direct is! bool) ||
      fingerprint is! String ||
      fingerprint.length > 64 * 1024 ||
      trustPhrase is! String ||
      trustPhrase.length > 4096 ||
      (trust && (fingerprint.isEmpty || trustPhrase.trim().isEmpty))) {
    return null;
  }
  return SecurityPromptDetails(
    peer: peer,
    peerId: peerId,
    direct: direct == true,
    fingerprint: fingerprint,
    trustPhrase: trustPhrase,
  );
}

List<WindowsSessionValue>? _decodeWindowsSessions(Object? raw) {
  final decoded = _decodeJsonInput(raw);
  if (decoded is! List || decoded.isEmpty || decoded.length > 256) {
    return null;
  }
  final sessions = <WindowsSessionValue>[];
  for (final value in decoded) {
    if (value is! Map) return null;
    final id = value['sid'];
    final name = value['name'];
    if (id is! String ||
        id.isEmpty ||
        id.length > 4096 ||
        name is! String ||
        name.length > 4096) {
      return null;
    }
    sessions.add(WindowsSessionValue(id: id, name: name));
  }
  return sessions;
}

SessionClientValue? _decodeClientValue(Object? raw) {
  final decoded = _decodeJsonInput(raw);
  if (decoded is! Map) return null;
  final id = _decodeInt(decoded['id']);
  if (id == null || id < 0 || id > 0x7fffffff) return null;

  bool? requiredBool(String key) => _decodeBool(decoded[key]);
  bool? optionalBool(String key, bool fallback) =>
      decoded.containsKey(key) ? _decodeBool(decoded[key]) : fallback;
  String? requiredString(String key) {
    final value = decoded[key];
    return value is String && value.length <= 64 * 1024 ? value : null;
  }

  final authorized = requiredBool('authorized');
  final isFileTransfer = requiredBool('is_file_transfer');
  final isViewCamera = requiredBool('is_view_camera');
  final isTerminal = optionalBool('is_terminal', false);
  final portForward = requiredString('port_forward');
  final clientName = requiredString('name');
  final avatar = decoded.containsKey('avatar') ? requiredString('avatar') : '';
  final peerId = requiredString('peer_id');
  final keyboard = requiredBool('keyboard');
  final clipboard = requiredBool('clipboard');
  final audio = requiredBool('audio');
  final file = requiredBool('file');
  final restart = requiredBool('restart');
  final recording = requiredBool('recording');
  final blockInput = requiredBool('block_input');
  final disconnected = requiredBool('disconnected');
  final fromSwitch = requiredBool('from_switch');
  final inVoiceCall = optionalBool('in_voice_call', false);
  final incomingVoiceCall = optionalBool('incoming_voice_call', false);
  if (authorized == null ||
      isFileTransfer == null ||
      isViewCamera == null ||
      isTerminal == null ||
      portForward == null ||
      clientName == null ||
      avatar == null ||
      peerId == null ||
      keyboard == null ||
      clipboard == null ||
      audio == null ||
      file == null ||
      restart == null ||
      recording == null ||
      blockInput == null ||
      disconnected == null ||
      fromSwitch == null ||
      inVoiceCall == null ||
      incomingVoiceCall == null) {
    return null;
  }
  return SessionClientValue(
    id: id,
    authorized: authorized,
    isFileTransfer: isFileTransfer,
    isViewCamera: isViewCamera,
    isTerminal: isTerminal,
    portForward: portForward,
    name: clientName,
    avatar: avatar,
    peerId: peerId,
    keyboard: keyboard,
    clipboard: clipboard,
    audio: audio,
    file: file,
    restart: restart,
    recording: recording,
    blockInput: blockInput,
    disconnected: disconnected,
    fromSwitch: fromSwitch,
    inVoiceCall: inVoiceCall,
    incomingVoiceCall: incomingVoiceCall,
  );
}

SessionEvent _decodePluginManagerEvent(Map<String, dynamic> event) {
  if (event.containsKey('plugin_list')) {
    final plugins = _decodePluginCatalog(event['plugin_list']);
    return plugins == null
        ? const InvalidSessionEvent('plugin_manager', 'invalid catalog')
        : PluginCatalogSessionEvent(plugins);
  }
  final install = event.containsKey('plugin_install');
  final uninstall = event.containsKey('plugin_uninstall');
  final id = _decodeBoundedString(event['id']);
  final message = install
      ? event['plugin_install']
      : uninstall
      ? event['plugin_uninstall']
      : null;
  return (!install && !uninstall) ||
          id == null ||
          id.isEmpty ||
          message is! String ||
          message.length > 64 * 1024
      ? const InvalidSessionEvent('plugin_manager', 'invalid status')
      : PluginInstallStatusSessionEvent(
          id: id,
          message: message,
          install: install,
        );
}

List<SessionPluginCatalogValue>? _decodePluginCatalog(Object? raw) {
  final decoded = _decodeJsonInput(raw, maxBytes: 4 * 1024 * 1024);
  if (decoded is! List || decoded.length > 1024) return null;
  final plugins = <SessionPluginCatalogValue>[];
  for (final value in decoded) {
    if (value is! Map) return null;
    final source = value['source'];
    final meta = value['meta'];
    if (source is! Map || meta is! Map) return null;
    String? text(Map map, String key, {bool required = false}) {
      final value = map[key] ?? '';
      if (value is! String || value.length > 64 * 1024) return null;
      return required && value.isEmpty ? null : value;
    }

    final sourceName = text(source, 'name', required: true);
    final sourceUrl = text(source, 'url');
    final sourceDescription = text(source, 'description');
    final id = text(meta, 'id', required: true);
    final name = text(meta, 'name', required: true);
    final version = text(meta, 'version', required: true);
    final description = text(meta, 'description');
    final author = text(meta, 'author', required: true);
    final home = text(meta, 'home');
    final license = text(meta, 'license');
    final sourceValue = text(meta, 'source');
    final installedVersion = value['installed_version'];
    final invalidReason = value['invalid_reason'] ?? '';
    final publishInfo = meta['publish_info'];
    if (sourceName == null ||
        sourceUrl == null ||
        sourceDescription == null ||
        id == null ||
        name == null ||
        version == null ||
        description == null ||
        author == null ||
        home == null ||
        license == null ||
        sourceValue == null ||
        installedVersion is! String ||
        installedVersion.length > 4096 ||
        invalidReason is! String ||
        invalidReason.length > 64 * 1024 ||
        publishInfo is! Map) {
      return null;
    }
    DateTime date(String key) {
      final value = publishInfo[key];
      return value is String
          ? DateTime.tryParse(value) ?? DateTime.utc(1970)
          : DateTime.utc(1970);
    }

    plugins.add(
      SessionPluginCatalogValue(
        sourceName: sourceName,
        sourceUrl: sourceUrl,
        sourceDescription: sourceDescription,
        id: id,
        name: name,
        version: version,
        description: description,
        author: author,
        home: home,
        license: license,
        source: sourceValue,
        lastReleased: date('last_released'),
        published: date('published'),
        installedVersion: installedVersion,
        invalidReason: invalidReason,
      ),
    );
  }
  return plugins;
}

List<SessionPluginUiValue>? _decodePluginUi(Object? raw) {
  final decoded = _decodeJsonInput(raw);
  if (decoded is! List || decoded.length > 1024) return null;
  final ui = <SessionPluginUiValue>[];
  for (final value in decoded) {
    if (value is! Map) return null;
    final type = value['t'];
    if (type != 'Button' && type != 'Checkbox') continue;
    final content = value['c'];
    if (content is! Map) return null;
    String? field(String key, {bool required = false}) {
      final value = content[key] ?? '';
      if (value is! String || value.length > 64 * 1024) return null;
      return required && value.isEmpty ? null : value;
    }

    final key = field('key', required: true);
    final text = field('text');
    final tooltip = field('tooltip');
    final action = field('action');
    final icon = field('icon');
    if (key == null ||
        text == null ||
        tooltip == null ||
        action == null ||
        icon == null) {
      return null;
    }
    ui.add(
      SessionPluginUiValue(
        kind: type == 'Button'
            ? SessionPluginUiKind.button
            : SessionPluginUiKind.checkbox,
        key: key,
        text: text,
        tooltip: tooltip,
        action: action,
        icon: icon,
      ),
    );
  }
  return ui;
}

SessionEvent _decodeCmFileLogEvent(Map<String, dynamic> event) {
  if (event.containsKey('transfer')) {
    final decoded = _decodeJsonInput(
      event['transfer'],
      maxBytes: 8 * 1024 * 1024,
    );
    final values = decoded is List ? decoded : [decoded];
    if (values.length > 65536) {
      return const InvalidSessionEvent(
        'cm_file_transfer_log',
        'transfer batch too large',
      );
    }
    final jobs = <SessionCmTransferJobValue>[];
    for (final value in values) {
      final job = _decodeCmTransferJob(value);
      if (job == null) {
        return const InvalidSessionEvent(
          'cm_file_transfer_log',
          'invalid transfer job',
        );
      }
      jobs.add(job);
    }
    return CmTransferLogSessionEvent(jobs);
  }
  if (event.containsKey('remove') || event.containsKey('create_dir')) {
    final remove = event.containsKey('remove');
    final decoded = _decodeJsonInput(
      remove ? event['remove'] : event['create_dir'],
    );
    if (decoded is! Map) {
      return const InvalidSessionEvent(
        'cm_file_transfer_log',
        'invalid file action',
      );
    }
    final connectionId = _decodeInt(decoded['connId']);
    final id = _decodeInt(decoded['id']);
    final path = decoded['path'];
    final directory = decoded['dir'];
    return connectionId == null ||
            connectionId < 0 ||
            id == null ||
            id < 0 ||
            path is! String ||
            path.length > 32 * 1024 ||
            directory is! bool
        ? const InvalidSessionEvent(
            'cm_file_transfer_log',
            'invalid file action fields',
          )
        : CmFileActionSessionEvent(
            kind: remove
                ? CmFileActionKind.remove
                : CmFileActionKind.createDirectory,
            connectionId: connectionId,
            id: id,
            path: path,
            directory: directory,
          );
  }
  if (event.containsKey('rename')) {
    final decoded = _decodeJsonInput(event['rename']);
    if (decoded is! Map) {
      return const InvalidSessionEvent(
        'cm_file_transfer_log',
        'invalid rename',
      );
    }
    final connectionId = _decodeInt(decoded['connId']);
    final path = decoded['path'];
    final newName = decoded['newName'];
    return connectionId == null ||
            connectionId < 0 ||
            path is! String ||
            path.length > 32 * 1024 ||
            newName is! String ||
            newName.length > 32 * 1024
        ? const InvalidSessionEvent(
            'cm_file_transfer_log',
            'invalid rename fields',
          )
        : CmFileRenameSessionEvent(
            connectionId: connectionId,
            path: path,
            newName: newName,
          );
  }
  return const InvalidSessionEvent('cm_file_transfer_log', 'missing action');
}

SessionCmTransferJobValue? _decodeCmTransferJob(Object? raw) {
  if (raw is! Map) return null;
  final connectionId = _decodeInt(raw['connId']);
  final id = _decodeInt(raw['id']);
  final path = raw['dataSource'];
  final isRemote = _decodeBool(raw['isRemote']);
  final totalSize = _decodeInt(raw['totalSize']);
  final finishedSize = _decodeInt(raw['finishedSize']);
  final transferred = _decodeInt(raw['transferred']);
  final done = _decodeBool(raw['done']);
  final cancel = _decodeBool(raw['cancel']);
  final error = raw['error'];
  if (connectionId == null ||
      connectionId < 0 ||
      id == null ||
      id < 0 ||
      path is! String ||
      path.length > 32 * 1024 ||
      isRemote == null ||
      totalSize == null ||
      totalSize < 0 ||
      finishedSize == null ||
      finishedSize < 0 ||
      transferred == null ||
      transferred < 0 ||
      done == null ||
      cancel == null ||
      error is! String ||
      error.length > 64 * 1024) {
    return null;
  }
  return SessionCmTransferJobValue(
    connectionId: connectionId,
    id: id,
    path: path,
    isRemote: isRemote,
    totalSize: totalSize,
    finishedSize: finishedSize,
    transferred: transferred,
    done: done,
    cancel: cancel,
    error: error,
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

Object? _decodeJsonInput(Object? raw, {int maxBytes = 1024 * 1024}) {
  if (raw is! String) return raw;
  if (raw.length > maxBytes) return null;
  try {
    return jsonDecode(raw);
  } catch (_) {
    return null;
  }
}

final class _FilePayloadBudget {
  int directories = 0;
  int entries = 0;
}

SessionFileDirectoryValue? _decodeFileDirectoryPayload(Object? raw) {
  final decoded = _decodeJsonInput(raw, maxBytes: 8 * 1024 * 1024);
  return _decodeFileDirectory(decoded, _FilePayloadBudget());
}

({String path, List<SessionFileDirectoryValue> directories})?
_decodeEmptyDirectoriesPayload(Object? raw) {
  final decoded = _decodeJsonInput(raw, maxBytes: 8 * 1024 * 1024);
  if (decoded is! Map) return null;
  final path = decoded['path'];
  final values = decoded['empty_dirs'];
  if (path is! String ||
      path.length > 32 * 1024 ||
      values is! List ||
      values.length > 8192) {
    return null;
  }
  final budget = _FilePayloadBudget();
  final directories = <SessionFileDirectoryValue>[];
  for (final value in values) {
    final directory = _decodeFileDirectory(value, budget);
    if (directory == null) return null;
    directories.add(directory);
  }
  return (path: path, directories: directories);
}

SessionFileDirectoryValue? _decodeFileDirectory(
  Object? raw,
  _FilePayloadBudget budget,
) {
  if (raw is! Map || ++budget.directories > 8192) return null;
  final id = _decodeInt(raw['id']);
  final path = raw['path'];
  final values = raw['entries'];
  if (id == null ||
      id < 0 ||
      id > 0x7fffffff ||
      path is! String ||
      path.length > 32 * 1024 ||
      values is! List ||
      values.length > 65536 ||
      budget.entries + values.length > 65536) {
    return null;
  }
  budget.entries += values.length;
  final entries = <SessionFileEntryValue>[];
  for (final value in values) {
    final entry = _decodeFileEntry(value);
    if (entry == null) return null;
    entries.add(entry);
  }
  return SessionFileDirectoryValue(id: id, path: path, entries: entries);
}

SessionFileEntryValue? _decodeFileEntry(Object? raw) {
  if (raw is! Map) return null;
  final entryType = _decodeInt(raw['entry_type']);
  final modifiedTime = _decodeInt(raw['modified_time']);
  final name = raw['name'];
  final size = _decodeInt(raw['size']);
  if (entryType == null ||
      entryType < 0 ||
      entryType > 255 ||
      modifiedTime == null ||
      name is! String ||
      name.length > 32 * 1024 ||
      size == null ||
      size < 0) {
    return null;
  }
  return SessionFileEntryValue(
    entryType: entryType,
    modifiedTime: modifiedTime,
    name: name,
    size: size,
  );
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
