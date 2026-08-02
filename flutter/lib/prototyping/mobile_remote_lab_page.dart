import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hbb/mobile/widgets/remote_session_controls.dart';
import 'package:path/path.dart' as path;

const _accentColor = Color(0xFF0071FF);
const _canvasColor = Color(0xFF212121);

ThemeData mobileRemoteLabTheme(Brightness brightness) {
  final colorScheme = ColorScheme.fromSeed(
    seedColor: _accentColor,
    brightness: brightness,
  );
  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: colorScheme,
    scaffoldBackgroundColor: colorScheme.surface,
  );
}

class RemoteLabMonitor {
  const RemoteLabMonitor({
    required this.name,
    required this.imagePath,
    required this.pixelSize,
    required this.origin,
  });

  final String name;
  final String imagePath;
  final Size pixelSize;
  final Offset origin;

  ImageProvider<Object>? get imageProvider =>
      imagePath.isEmpty ? null : FileImage(File(imagePath));
}

enum RemoteLabScenario {
  windowsFullAccess,
  androidPeer,
  viewOnly,
  connecting,
  disconnected,
}

extension RemoteLabScenarioDetails on RemoteLabScenario {
  String get label => switch (this) {
    RemoteLabScenario.windowsFullAccess =>
      'Windows · full access · multi-monitor',
    RemoteLabScenario.androidPeer => 'Android peer · full access',
    RemoteLabScenario.viewOnly => 'Windows · view only',
    RemoteLabScenario.connecting => 'Connecting',
    RemoteLabScenario.disconnected => 'Disconnected',
  };

  bool get connected =>
      this != RemoteLabScenario.connecting &&
      this != RemoteLabScenario.disconnected;
  bool get peerIsAndroid => this == RemoteLabScenario.androidPeer;
  bool get viewOnly => this == RemoteLabScenario.viewOnly;
}

class MobileRemoteLabPage extends StatefulWidget {
  const MobileRemoteLabPage({
    super.key,
    required this.initialScreensDirectory,
    required this.themeMode,
    required this.onThemeModeChanged,
    this.initialMonitors,
  });

  final String initialScreensDirectory;
  final ThemeMode themeMode;
  final ValueChanged<ThemeMode> onThemeModeChanged;
  final List<RemoteLabMonitor>? initialMonitors;

  @override
  State<MobileRemoteLabPage> createState() => _MobileRemoteLabPageState();
}

class _DevicePreset {
  const _DevicePreset(
    this.name,
    this.logicalSize,
    this.devicePixelRatio, {
    required this.platform,
    required this.portraitViewPadding,
  });

  final String name;
  final Size logicalSize;
  final double devicePixelRatio;
  final TargetPlatform platform;
  final EdgeInsets portraitViewPadding;

  String get platformLabel => switch (platform) {
    TargetPlatform.android => 'Android',
    TargetPlatform.iOS => 'iOS',
    _ => platform.name,
  };

  EdgeInsets viewPadding({required bool portrait}) {
    if (portrait) {
      return portraitViewPadding;
    }
    return EdgeInsets.fromLTRB(
      portraitViewPadding.top,
      0,
      portraitViewPadding.bottom,
      0,
    );
  }
}

const _devicePresets = <_DevicePreset>[
  _DevicePreset(
    'Redmi Note class · Android',
    Size(393, 873),
    2.75,
    platform: TargetPlatform.android,
    portraitViewPadding: EdgeInsets.fromLTRB(0, 32, 0, 16),
  ),
  _DevicePreset(
    'Compact phone · Android',
    Size(360, 800),
    3,
    platform: TargetPlatform.android,
    portraitViewPadding: EdgeInsets.fromLTRB(0, 24, 0, 16),
  ),
  _DevicePreset(
    'Large phone · Android',
    Size(430, 932),
    3,
    platform: TargetPlatform.android,
    portraitViewPadding: EdgeInsets.fromLTRB(0, 32, 0, 16),
  ),
  _DevicePreset(
    'iPhone 15 class · iOS',
    Size(393, 852),
    3,
    platform: TargetPlatform.iOS,
    portraitViewPadding: EdgeInsets.fromLTRB(0, 59, 0, 34),
  ),
  _DevicePreset(
    'Small tablet · Android',
    Size(800, 1280),
    2,
    platform: TargetPlatform.android,
    portraitViewPadding: EdgeInsets.fromLTRB(0, 24, 0, 16),
  ),
];

class _MobileRemoteLabPageState extends State<MobileRemoteLabPage> {
  List<RemoteLabMonitor> _monitors = const [];
  _DevicePreset _devicePreset = _devicePresets.first;
  String _screensDirectory = '';
  String? _loadError;
  bool _portrait = true;
  bool _loading = false;
  RemoteLabScenario _scenario = RemoteLabScenario.windowsFullAccess;

  @override
  void initState() {
    super.initState();
    final initialMonitors = widget.initialMonitors;
    if (initialMonitors != null) {
      _monitors = initialMonitors;
    } else {
      unawaited(_loadInitialScreens());
    }
  }

  Future<void> _loadInitialScreens() async {
    final configured = widget.initialScreensDirectory.trim();
    if (configured.isNotEmpty) {
      await _loadScreens(configured);
      return;
    }

    for (final candidate in _defaultScreensDirectories()) {
      final directory = Directory(candidate);
      if (await directory.exists()) {
        await _loadScreens(candidate);
        if (_monitors.isNotEmpty) {
          return;
        }
      }
    }

    if (!mounted) {
      return;
    }
    setState(() {
      _loadError = 'No screenshots were found. Choose rustadmin-tests/screens.';
    });
  }

  Iterable<String> _defaultScreensDirectories() sync* {
    final current = Directory.current.path;
    yield path.normalize(
      path.join(current, '..', '..', 'rustadmin-tests', 'screens'),
    );
    yield path.normalize(
      path.join(current, '..', 'rustadmin-tests', 'screens'),
    );
    yield path.normalize(path.join(current, 'rustadmin-tests', 'screens'));
  }

  Future<void> _chooseScreensDirectory() async {
    final selected = await FilePicker.getDirectoryPath(
      dialogTitle: 'Choose a folder containing monitor screenshots',
      initialDirectory: _screensDirectory.isEmpty ? null : _screensDirectory,
    );
    if (selected != null) {
      await _loadScreens(selected);
    }
  }

  Future<void> _loadScreens(String directoryPath) async {
    if (!mounted) {
      return;
    }
    setState(() {
      _loading = true;
      _loadError = null;
    });

    try {
      final directory = Directory(directoryPath);
      final files = await directory
          .list(followLinks: false)
          .where(
            (entry) =>
                entry is File &&
                const {
                  '.png',
                  '.jpg',
                  '.jpeg',
                }.contains(path.extension(entry.path).toLowerCase()),
          )
          .cast<File>()
          .toList();
      files.sort(
        (left, right) =>
            path.basename(left.path).compareTo(path.basename(right.path)),
      );

      final monitors = <RemoteLabMonitor>[];
      double x = 0;
      for (var index = 0; index < files.length; index++) {
        final pixelSize = await _readImageSize(files[index]);
        monitors.add(
          RemoteLabMonitor(
            name: 'Monitor ${index + 1}',
            imagePath: files[index].path,
            pixelSize: pixelSize,
            origin: Offset(x, 0),
          ),
        );
        x += pixelSize.width;
      }

      if (!mounted) {
        return;
      }
      setState(() {
        _screensDirectory = directoryPath;
        _monitors = monitors;
        _loadError = monitors.isEmpty
            ? 'The selected folder contains no PNG or JPEG screenshots.'
            : null;
      });
      debugPrint(
        'Mobile Remote Lab loaded ${monitors.length} monitor screenshots '
        'from $directoryPath',
      );
    } on FileSystemException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _loadError = error.message;
        _monitors = const [];
      });
    } on FormatException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _loadError = error.message;
        _monitors = const [];
      });
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  Future<Size> _readImageSize(File file) async {
    final bytes = await file.readAsBytes();
    ui.Codec? codec;
    ui.FrameInfo? frame;
    try {
      codec = await ui.instantiateImageCodec(bytes);
      frame = await codec.getNextFrame();
      return Size(frame.image.width.toDouble(), frame.image.height.toDouble());
    } catch (error) {
      throw FormatException(
        'Unable to read ${path.basename(file.path)}: $error',
      );
    } finally {
      frame?.image.dispose();
      codec?.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerLowest,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final controls = _buildControls(context);
            final preview = _buildPreview(context);
            if (constraints.maxWidth < 1050) {
              return Column(
                children: [
                  SizedBox(height: 260, child: controls),
                  Expanded(child: preview),
                ],
              );
            }
            return Row(
              children: [
                SizedBox(width: 330, child: controls),
                VerticalDivider(
                  width: 1,
                  color: Theme.of(context).dividerColor,
                ),
                Expanded(child: preview),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildControls(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Material(
      color: colorScheme.surface,
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(
            'Mobile Remote Lab',
            style: Theme.of(
              context,
            ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          Text(
            'Static remote screens with the mobile RustAdmin control shell.',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 22),
          Text('Screens', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          Text(
            _screensDirectory.isEmpty
                ? 'No folder selected'
                : _screensDirectory,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall,
          ),
          if (_loadError != null) ...[
            const SizedBox(height: 6),
            Text(_loadError!, style: TextStyle(color: colorScheme.error)),
          ],
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.tonalIcon(
                onPressed: _loading ? null : _chooseScreensDirectory,
                icon: const Icon(Icons.folder_open),
                label: const Text('Choose folder'),
              ),
              IconButton.outlined(
                onPressed: _loading || _screensDirectory.isEmpty
                    ? null
                    : () => _loadScreens(_screensDirectory),
                tooltip: 'Reload screenshots',
                icon: _loading
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh),
              ),
            ],
          ),
          const SizedBox(height: 22),
          DropdownButtonFormField<RemoteLabScenario>(
            initialValue: _scenario,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: 'Remote-session scenario',
              border: OutlineInputBorder(),
            ),
            items: [
              for (final scenario in RemoteLabScenario.values)
                DropdownMenuItem(
                  value: scenario,
                  child: Text(
                    scenario.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: (value) {
              if (value != null) {
                setState(() {
                  _scenario = value;
                });
              }
            },
          ),
          const SizedBox(height: 16),
          DropdownButtonFormField<_DevicePreset>(
            initialValue: _devicePreset,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: 'Device viewport',
              border: OutlineInputBorder(),
            ),
            items: _devicePresets
                .map(
                  (preset) => DropdownMenuItem(
                    value: preset,
                    child: Text(
                      preset.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                )
                .toList(),
            onChanged: (value) {
              if (value != null) {
                setState(() {
                  _devicePreset = value;
                });
              }
            },
          ),
          const SizedBox(height: 16),
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(
                value: true,
                icon: Icon(Icons.stay_current_portrait),
                label: Text('Portrait'),
              ),
              ButtonSegment(
                value: false,
                icon: Icon(Icons.stay_current_landscape),
                label: Text('Landscape'),
              ),
            ],
            selected: {_portrait},
            onSelectionChanged: (value) {
              setState(() {
                _portrait = value.first;
              });
            },
          ),
          const SizedBox(height: 16),
          DropdownButtonFormField<ThemeMode>(
            initialValue: widget.themeMode,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: 'Theme',
              border: OutlineInputBorder(),
            ),
            items: const [
              DropdownMenuItem(value: ThemeMode.system, child: Text('System')),
              DropdownMenuItem(value: ThemeMode.light, child: Text('Light')),
              DropdownMenuItem(value: ThemeMode.dark, child: Text('Dark')),
            ],
            onChanged: (value) {
              if (value != null) {
                widget.onThemeModeChanged(value);
              }
            },
          ),
          const SizedBox(height: 22),
          _metric('Loaded monitors', _monitors.length.toString()),
          _metric(
            'Logical viewport',
            _portrait
                ? '${_devicePreset.logicalSize.width.toInt()} × '
                      '${_devicePreset.logicalSize.height.toInt()}'
                : '${_devicePreset.logicalSize.height.toInt()} × '
                      '${_devicePreset.logicalSize.width.toInt()}',
          ),
          _metric(
            'Device pixel ratio',
            _devicePreset.devicePixelRatio.toStringAsFixed(2),
          ),
          _metric('Simulated platform', _devicePreset.platformLabel),
          const SizedBox(height: 18),
          Text(
            'Mouse drag simulates panning. Use the wheel or trackpad to zoom. '
            'The monitor button switches between individual screens and the '
            'combined desktop.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  Widget _metric(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Expanded(child: Text(label)),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }

  Widget _buildPreview(BuildContext context) {
    final baseSize = _devicePreset.logicalSize;
    final viewport = _portrait
        ? baseSize
        : Size(baseSize.height, baseSize.width);
    final viewPadding = _devicePreset.viewPadding(portrait: _portrait);
    final previewNavigatorKey = ValueKey(
      Object.hash(
        _scenario,
        Object.hashAll(_monitors),
        _devicePreset.name,
        _portrait,
      ),
    );
    final previewTheme = Theme.of(
      context,
    ).copyWith(platform: _devicePreset.platform);
    return ColoredBox(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: FittedBox(
            fit: BoxFit.contain,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.black,
                borderRadius: BorderRadius.circular(42),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x55000000),
                    blurRadius: 26,
                    offset: Offset(0, 12),
                  ),
                ],
              ),
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(32),
                  child: SizedBox(
                    key: const Key('mobile-remote-device-viewport'),
                    width: viewport.width,
                    height: viewport.height,
                    child: Theme(
                      data: previewTheme,
                      child: MediaQuery(
                        data: MediaQueryData(
                          size: viewport,
                          devicePixelRatio: _devicePreset.devicePixelRatio,
                          textScaler: TextScaler.noScaling,
                          platformBrightness: Theme.of(context).brightness,
                          padding: viewPadding,
                          viewPadding: viewPadding,
                          systemGestureInsets: viewPadding,
                        ),
                        child: ScaffoldMessenger(
                          child: Navigator(
                            key: previewNavigatorKey,
                            onGenerateRoute: (settings) =>
                                MaterialPageRoute<void>(
                                  settings: settings,
                                  builder: (context) => MobileRemotePreview(
                                    monitors: _monitors,
                                    scenario: _scenario,
                                  ),
                                ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

enum _RemotePanel { displays, chat }

class MobileRemotePreview extends StatefulWidget {
  const MobileRemotePreview({
    super.key,
    required this.monitors,
    this.scenario = RemoteLabScenario.windowsFullAccess,
  });

  final List<RemoteLabMonitor> monitors;
  final RemoteLabScenario scenario;

  @override
  State<MobileRemotePreview> createState() => _MobileRemotePreviewState();
}

class _MobileRemotePreviewState extends State<MobileRemotePreview> {
  static const _allMonitors = -1;

  final TransformationController _transformationController =
      TransformationController();

  int _selectedMonitor = 0;
  late bool _connected;
  bool _showToolbar = true;
  bool _showKeyboard = false;
  bool _keyboardCtrl = false;
  bool _keyboardAlt = false;
  bool _keyboardShift = false;
  bool _keyboardCommand = false;
  bool _keyboardFunctionKeys = false;
  bool _keyboardPinned = false;
  bool _keyboardMoreKeys = true;
  bool _touchMode = true;
  bool _showGestureHelp = false;
  bool _showAndroidActions = false;
  _RemotePanel? _panel;

  @override
  void initState() {
    super.initState();
    _connected = widget.scenario.connected;
  }

  @override
  void didUpdateWidget(covariant MobileRemotePreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_selectedMonitor >= widget.monitors.length) {
      _selectedMonitor = widget.monitors.isEmpty
          ? 0
          : widget.monitors.length - 1;
    }
    if (oldWidget.scenario != widget.scenario) {
      _connected = widget.scenario.connected;
      _showToolbar = widget.scenario != RemoteLabScenario.connecting;
      _showKeyboard = false;
      _keyboardCtrl = false;
      _keyboardAlt = false;
      _keyboardShift = false;
      _keyboardCommand = false;
      _keyboardFunctionKeys = false;
      _keyboardPinned = false;
      _keyboardMoreKeys = true;
      _showGestureHelp = false;
      _showAndroidActions = widget.scenario.peerIsAndroid && _connected;
      _panel = null;
    }
    _resetView();
  }

  @override
  void dispose() {
    _transformationController.dispose();
    super.dispose();
  }

  void _resetView() {
    _transformationController.value = Matrix4.identity();
  }

  void _selectMonitor(int value) {
    setState(() {
      _selectedMonitor = value;
      _panel = null;
    });
    _resetView();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _canvasColor,
      body: Stack(
        children: [
          Positioned.fill(child: _buildRemoteCanvas(context)),
          Positioned(left: 10, top: 10, child: _buildScreenLabel(context)),
          if (widget.scenario == RemoteLabScenario.connecting)
            Positioned.fill(child: _buildConnecting(context)),
          if (!_connected && widget.scenario != RemoteLabScenario.connecting)
            Positioned.fill(child: _buildDisconnected(context)),
          if (_showGestureHelp)
            Positioned.fill(child: _buildGestureHelp(context)),
          if (_showKeyboard && _connected)
            Align(
              alignment: Alignment.bottomCenter,
              child: _buildKeyboard(context),
            ),
          if (_panel != null) Positioned.fill(child: _buildPanel(context)),
          if (_showAndroidActions && _connected)
            Positioned(
              left: 96,
              bottom: 12,
              width: 200,
              height: 45,
              child: MobileRemoteAndroidActionsBar(
                scale: 1,
                onBack: () => _showPreviewAction('Back'),
                onHome: () => _showPreviewAction('Home'),
                onRecent: () => _showPreviewAction('Apps'),
                onHide: () {
                  setState(() {
                    _showAndroidActions = false;
                  });
                },
              ),
            ),
        ],
      ),
      bottomNavigationBar: _showToolbar && _connected
          ? _buildBottomToolbar(context)
          : null,
      floatingActionButton: _showToolbar || !_connected
          ? null
          : FloatingActionButton.small(
              tooltip: 'Show toolbar',
              backgroundColor: _accentColor,
              foregroundColor: Colors.white,
              onPressed: () {
                setState(() {
                  _showToolbar = true;
                });
              },
              child: const Icon(Icons.expand_less),
            ),
    );
  }

  Widget _buildRemoteCanvas(BuildContext context) {
    if (widget.monitors.isEmpty) {
      return ColoredBox(
        color: _canvasColor,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              'Choose a screenshot folder to populate the remote displays.',
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.bodyLarge?.copyWith(color: Colors.white70),
            ),
          ),
        ),
      );
    }

    return ClipRect(
      child: InteractiveViewer(
        transformationController: _transformationController,
        minScale: 1,
        maxScale: 6,
        panEnabled: _connected,
        scaleEnabled: _connected,
        child: ColoredBox(
          color: Colors.black,
          child: _selectedMonitor == _allMonitors
              ? _buildCombinedDesktop()
              : _buildSingleMonitor(widget.monitors[_selectedMonitor]),
        ),
      ),
    );
  }

  Widget _buildSingleMonitor(RemoteLabMonitor monitor) {
    final provider = monitor.imageProvider;
    if (provider == null) {
      return _monitorPlaceholder(monitor.name);
    }
    return Image(
      image: provider,
      fit: BoxFit.contain,
      filterQuality: FilterQuality.medium,
      errorBuilder: (context, error, stackTrace) =>
          _monitorPlaceholder('${monitor.name}\n$imageLoadFailure'),
    );
  }

  static const imageLoadFailure = 'Unable to load screenshot';

  Widget _buildCombinedDesktop() {
    final bounds = _monitorBounds(widget.monitors);
    return FittedBox(
      fit: BoxFit.contain,
      child: SizedBox(
        width: bounds.width,
        height: bounds.height,
        child: Stack(
          children: [
            for (final monitor in widget.monitors)
              Positioned(
                left: monitor.origin.dx - bounds.left,
                top: monitor.origin.dy - bounds.top,
                width: monitor.pixelSize.width,
                height: monitor.pixelSize.height,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.black, width: 4),
                  ),
                  child: _buildSingleMonitor(monitor),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Rect _monitorBounds(List<RemoteLabMonitor> monitors) {
    var left = monitors.first.origin.dx;
    var top = monitors.first.origin.dy;
    var right = left + monitors.first.pixelSize.width;
    var bottom = top + monitors.first.pixelSize.height;
    for (final monitor in monitors.skip(1)) {
      left = left < monitor.origin.dx ? left : monitor.origin.dx;
      top = top < monitor.origin.dy ? top : monitor.origin.dy;
      final monitorRight = monitor.origin.dx + monitor.pixelSize.width;
      final monitorBottom = monitor.origin.dy + monitor.pixelSize.height;
      right = right > monitorRight ? right : monitorRight;
      bottom = bottom > monitorBottom ? bottom : monitorBottom;
    }
    return Rect.fromLTRB(left, top, right, bottom);
  }

  Widget _monitorPlaceholder(String text) {
    return ColoredBox(
      color: const Color(0xFF263238),
      child: Center(
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.white70),
        ),
      ),
    );
  }

  Widget _buildScreenLabel(BuildContext context) {
    final label = widget.monitors.isEmpty
        ? 'No displays'
        : _selectedMonitor == _allMonitors
        ? 'All monitors'
        : widget.monitors[_selectedMonitor].name;
    return Material(
      color: Colors.black.withValues(alpha: 0.58),
      borderRadius: BorderRadius.circular(14),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        child: Text(
          label,
          key: const Key('selected-monitor-label'),
          style: Theme.of(
            context,
          ).textTheme.labelMedium?.copyWith(color: Colors.white),
        ),
      ),
    );
  }

  Widget _buildBottomToolbar(BuildContext context) {
    return MobileRemoteBottomBar(
      onDisconnect: () {
        setState(() {
          _connected = false;
          _showKeyboard = false;
          _showAndroidActions = false;
          _panel = null;
        });
      },
      onOptions: () {
        setState(() {
          _showKeyboard = false;
          _panel = _RemotePanel.displays;
        });
      },
      onKeyboard: () {
        setState(() {
          _showKeyboard = !_showKeyboard;
          _panel = null;
        });
      },
      onGestureHelp: () {
        setState(() {
          _showGestureHelp = !_showGestureHelp;
        });
      },
      onMobileActions: () {
        setState(() {
          _showAndroidActions = !_showAndroidActions;
        });
      },
      onMore: _showMoreMenu,
      onHide: () {
        setState(() {
          _showToolbar = false;
          _panel = null;
        });
      },
      showInputControls: !widget.scenario.viewOnly,
      peerIsAndroid: widget.scenario.peerIsAndroid,
      touchMode: _touchMode,
      waitForFirstImage: false,
      chatButton: IconButton(
        tooltip: 'Chat',
        color: Colors.white,
        icon: const Icon(Icons.message),
        onPressed: _showChatMenu,
      ),
    );
  }

  Widget _buildPanel(BuildContext context) {
    return Material(
      color: Colors.black54,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          setState(() {
            _panel = null;
          });
        },
        child: Align(
          alignment: Alignment.bottomCenter,
          child: GestureDetector(
            onTap: () {},
            child: Material(
              color: Theme.of(context).colorScheme.surface,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(20),
              ),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.sizeOf(context).height * 0.84,
                ),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(20, 14, 20, 24),
                  child: switch (_panel!) {
                    _RemotePanel.displays => _buildDisplayPanel(context),
                    _RemotePanel.chat => _buildChatPanel(context),
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDisplayPanel(BuildContext context) {
    final enabled = !widget.scenario.viewOnly;
    return MobileRemoteOptionsContent(
      key: ValueKey(widget.scenario),
      header: [
        Text('Displays', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 12),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: 8,
          runSpacing: 8,
          children: [
            for (var index = 0; index < widget.monitors.length; index++)
              _displayButton(
                label: '${index + 1}',
                selected: _selectedMonitor == index,
                onTap: () => _selectMonitor(index),
              ),
            if (widget.monitors.length > 1)
              _displayButton(
                label: 'All',
                selected: _selectedMonitor == _allMonitors,
                onTap: () => _selectMonitor(_allMonitors),
                width: 54,
              ),
          ],
        ),
        const Divider(),
      ],
      radioSections: [
        _radioSection('view-style', 'adaptive', const [
          ('original', 'Scale original'),
          ('adaptive', 'Scale adaptive'),
          ('custom', 'Scale custom'),
        ], heading: 'Scale'),
        _radioSection(
          'image-quality',
          'balanced',
          const [
            ('best', 'Good image quality'),
            ('balanced', 'Balanced'),
            ('low', 'Optimize reaction time'),
            ('custom', 'Custom'),
          ],
          heading: 'Image quality',
          selectionDetailsBuilder: (value) => value == 'custom'
              ? _buildCustomImageQualityPreview()
              : const SizedBox.shrink(),
        ),
        _radioSection('codec', 'auto', const [
          ('auto', 'Auto (VP9)'),
          ('vp8', 'VP8'),
          ('vp9', 'VP9'),
          ('av1', 'AV1'),
          ('av1-hw', 'AV1 HW'),
          ('h264', 'H264'),
          ('h264-hq', 'H264 HQ'),
          ('h265', 'H265'),
          ('h265-hq', 'H265 HQ'),
        ], heading: 'Codec'),
        if (!widget.scenario.peerIsAndroid)
          _radioSection('capture-backend', 'auto', const [
            ('auto', 'Auto (DXGI)'),
            ('dxgi', 'DXGI'),
            ('wgc', 'WGC'),
            ('winmag', 'WinMag'),
            ('gdi', 'GDI'),
          ], heading: 'Capture'),
        _radioSection('quality-monitor', 'disabled', const [
          ('disabled', 'Disabled'),
          ('top-right', 'Top right'),
          ('top-left', 'Top left'),
          ('bottom-right', 'Bottom right'),
          ('bottom-left', 'Bottom left'),
        ], heading: 'Quality monitor'),
        _radioSection('quality-monitor-details', 'basic', const [
          ('basic', 'Basic'),
          ('extended', 'Extended'),
        ], heading: 'Quality monitor details'),
        _radioSection(
          'clipboard',
          enabled ? 'bidirectional' : 'off',
          const [
            ('bidirectional', 'Bidirectional'),
            ('host-to-client', 'Host to client'),
            ('client-to-host', 'Client to host'),
            ('off', 'Disabled'),
          ],
          heading: 'Clipboard',
          enabled: enabled,
        ),
      ],
      actions: [
        if (!widget.scenario.peerIsAndroid)
          MobileRemoteActionItem(
            child: const Text('Resolution'),
            onPressed: _showResolutionMenu,
          ),
        if (!widget.scenario.peerIsAndroid)
          MobileRemoteActionItem(
            child: const Text('Virtual display'),
            onPressed: _showVirtualDisplayMenu,
          ),
      ],
      toggles: [
        if (!widget.scenario.peerIsAndroid)
          MobileRemoteToggleItem(
            id: 'show-remote-cursor',
            value: true,
            child: const Text('Show remote cursor'),
            onChanged: enabled ? (_) {} : null,
          ),
        if (!widget.scenario.peerIsAndroid && widget.monitors.length > 1)
          MobileRemoteToggleItem(
            id: 'follow-remote-cursor',
            value: false,
            child: const Text('Follow remote cursor'),
            onChanged: enabled ? (_) {} : null,
          ),
        if (!widget.scenario.peerIsAndroid && widget.monitors.length > 1)
          MobileRemoteToggleItem(
            id: 'follow-remote-window',
            value: false,
            child: const Text('Follow remote window focus'),
            onChanged: enabled ? (_) {} : null,
          ),
        MobileRemoteToggleItem(
          id: 'mute',
          value: false,
          child: const Text('Mute'),
          onChanged: (_) {},
          dividerBefore: !widget.scenario.peerIsAndroid,
        ),
        if (!widget.scenario.peerIsAndroid)
          MobileRemoteToggleItem(
            id: 'file-copy-paste',
            value: true,
            child: const Text('Enable file copy and paste'),
            onChanged: enabled ? (_) {} : null,
          ),
        if (!widget.scenario.peerIsAndroid)
          MobileRemoteToggleItem(
            id: 'lock-after-session',
            value: false,
            child: const Text('Lock after session end'),
            onChanged: enabled ? (_) {} : null,
          ),
        MobileRemoteToggleItem(
          id: 'true-color',
          value: false,
          child: const Text('True color (4:4:4)'),
          onChanged: (_) {},
        ),
        MobileRemoteToggleItem(
          id: 'reverse-wheel',
          value: false,
          child: const Text('Reverse mouse wheel'),
          onChanged: enabled ? (_) {} : null,
        ),
        MobileRemoteToggleItem(
          id: 'swap-buttons',
          value: false,
          child: const Text('Swap left and right mouse buttons'),
          onChanged: enabled ? (_) {} : null,
        ),
        MobileRemoteToggleItem(
          id: 'view-mode',
          value: widget.scenario.viewOnly,
          child: const Text('View Mode'),
          onChanged: (_) {},
        ),
        if (!widget.scenario.peerIsAndroid)
          MobileRemoteToggleItem(
            id: 'privacy-mode',
            value: false,
            child: const Text('Privacy mode'),
            onChanged: enabled ? (_) {} : null,
          ),
      ],
    );
  }

  Widget _displayButton({
    required String label,
    required bool selected,
    required VoidCallback onTap,
    double width = 40,
  }) {
    return InkWell(
      onTap: onTap,
      child: Ink(
        width: width,
        height: 40,
        decoration: BoxDecoration(
          border: Border.all(color: Theme.of(context).hintColor),
          borderRadius: BorderRadius.circular(2),
          color: selected
              ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.6)
              : null,
        ),
        child: Center(
          child: Text(
            label,
            style: TextStyle(
              color: selected ? Colors.white : null,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ),
    );
  }

  MobileRemoteRadioSection _radioSection(
    String id,
    String selected,
    List<(String, String)> values, {
    String? heading,
    bool enabled = true,
    Widget Function(String value)? selectionDetailsBuilder,
  }) {
    return MobileRemoteRadioSection(
      id: id,
      value: selected,
      heading: heading == null ? null : Text(heading),
      selectionDetailsBuilder: selectionDetailsBuilder,
      items: [
        for (final value in values)
          MobileRemoteRadioItem(
            value: value.$1,
            child: Text(value.$2),
            onChanged: enabled ? (_) {} : null,
          ),
      ],
    );
  }

  Widget _buildCustomImageQualityPreview() {
    return Padding(
      key: const Key('mobile-custom-image-quality-preview'),
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Expanded(child: Slider(value: 0.5, onChanged: null)),
              Text('50% Bitrate'),
            ],
          ),
          const Row(
            children: [
              Expanded(child: Slider(value: 0.5, onChanged: null)),
              Text('30 FPS'),
            ],
          ),
          const Text('FPS mode'),
          const SizedBox(height: 6),
          SizedBox(
            width: double.infinity,
            child: SegmentedButton<String>(
              expandedInsets: EdgeInsets.zero,
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: 'adaptive', label: Text('Adaptive')),
                ButtonSegment(value: 'fixed', label: Text('Fixed')),
              ],
              selected: const {'adaptive'},
              onSelectionChanged: (_) {},
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildChatPanel(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Text chat', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 10),
        const Align(
          alignment: Alignment.centerLeft,
          child: Chip(label: Text('Static UI preview session')),
        ),
        const SizedBox(height: 8),
        const TextField(
          decoration: InputDecoration(
            hintText: 'Type a preview message',
            border: OutlineInputBorder(),
            suffixIcon: Icon(Icons.send),
          ),
        ),
      ],
    );
  }

  Future<void> _showChatMenu() async {
    await showMobileRemotePopupMenu(context, [
      MobileRemoteMenuItem(
        child: const Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [Text('Text chat'), Icon(Icons.message)],
        ),
        onPressed: () {
          setState(() {
            _panel = _RemotePanel.chat;
          });
        },
      ),
      MobileRemoteMenuItem(
        child: const Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [Text('Voice call'), Icon(Icons.call)],
        ),
        onPressed: () => _showPreviewAction('Voice call'),
      ),
    ]);
  }

  Future<void> _showMoreMenu() async {
    final androidActions = <String>[
      if (widget.scenario.peerIsAndroid) ...[
        'Back',
        'Home',
        'Apps',
        'Volume up',
        'Volume down',
        'Power',
      ],
    ];
    final sessionActions = <String>[
      if (!widget.scenario.viewOnly) 'Request Elevation',
      'OS Password',
      if (!widget.scenario.peerIsAndroid && !widget.scenario.viewOnly)
        'Show sign-in',
      if (!widget.scenario.peerIsAndroid) 'Send clipboard keystrokes',
      'Reset canvas',
      'Note',
      if (!widget.scenario.peerIsAndroid && !widget.scenario.viewOnly)
        'Insert Ctrl + Alt + Del',
      if (!widget.scenario.peerIsAndroid) 'Restart remote device',
      if (!widget.scenario.viewOnly) 'Insert Lock',
      if (!widget.scenario.peerIsAndroid) 'Block user input',
      'Refresh',
      'Start session recording',
      'Copy Fingerprint',
    ];

    await showMobileRemotePopupMenu(context, [
      for (final action in androidActions)
        MobileRemoteMenuItem(
          child: Text(action),
          onPressed: () => _showPreviewAction(action),
        ),
      for (var index = 0; index < sessionActions.length; index++)
        MobileRemoteMenuItem(
          child: Text(sessionActions[index]),
          dividerBefore: index == 0 && androidActions.isNotEmpty,
          onPressed: sessionActions[index] == 'Reset canvas'
              ? () {
                  _resetView();
                  _showPreviewAction('Reset canvas');
                }
              : () => _showPreviewAction(sessionActions[index]),
        ),
    ]);
  }

  void _showPreviewAction(String action) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          duration: const Duration(milliseconds: 900),
          content: Text('$action · preview only'),
        ),
      );
  }

  Future<void> _showResolutionMenu() async {
    var selected = '2560x1440';
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Resolution'),
          content: RadioGroup<String>(
            groupValue: selected,
            onChanged: (value) {
              if (value != null) {
                setDialogState(() {
                  selected = value;
                });
              }
            },
            child: const Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                RadioListTile(value: '1920x1080', title: Text('1920x1080')),
                RadioListTile(value: '2560x1440', title: Text('2560x1440')),
                RadioListTile(value: '3840x2160', title: Text('3840x2160')),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _showVirtualDisplayMenu() async {
    final enabled = <bool>[true, false, false, false];
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Virtual display'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var index = 0; index < enabled.length; index++)
                CheckboxListTile(
                  value: enabled[index],
                  title: Text('Virtual display ${index + 1}'),
                  onChanged: (value) {
                    setDialogState(() {
                      enabled[index] = value ?? false;
                    });
                  },
                ),
              TextButton(
                onPressed: () {
                  setDialogState(() {
                    enabled.fillRange(0, enabled.length, false);
                  });
                },
                child: const Text('Plug out all'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildKeyboard(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        MobileRemoteKeyHelpTools(
          key: const Key('mobile-remote-key-help-tools'),
          keyboardIsVisible: true,
          ctrlActive: _keyboardCtrl,
          altActive: _keyboardAlt,
          shiftActive: _keyboardShift,
          commandActive: _keyboardCommand,
          functionKeysActive: _keyboardFunctionKeys,
          pinned: _keyboardPinned,
          moreKeysActive: _keyboardMoreKeys,
          isMac: false,
          showWindowsLinuxKeys: !widget.scenario.peerIsAndroid,
          onCtrl: () {
            setState(() {
              _keyboardCtrl = !_keyboardCtrl;
            });
          },
          onAlt: () {
            setState(() {
              _keyboardAlt = !_keyboardAlt;
            });
          },
          onShift: () {
            setState(() {
              _keyboardShift = !_keyboardShift;
            });
          },
          onCommand: () {
            setState(() {
              _keyboardCommand = !_keyboardCommand;
            });
          },
          onFunctionKeys: () {
            setState(() {
              _keyboardFunctionKeys = !_keyboardFunctionKeys;
              if (_keyboardFunctionKeys) {
                _keyboardMoreKeys = false;
              }
            });
          },
          onPin: () {
            setState(() {
              _keyboardPinned = !_keyboardPinned;
            });
          },
          onMoreKeys: () {
            setState(() {
              _keyboardMoreKeys = !_keyboardMoreKeys;
              if (_keyboardMoreKeys) {
                _keyboardFunctionKeys = false;
              }
            });
          },
          onKeyPressed: _showPreviewAction,
          onShortcutPressed: _showPreviewAction,
        ),
        _buildSimulatedSystemKeyboard(context),
      ],
    );
  }

  Widget _buildSimulatedSystemKeyboard(BuildContext context) {
    const rows = [
      ['Q', 'W', 'E', 'R', 'T', 'Y', 'U', 'I', 'O', 'P'],
      ['A', 'S', 'D', 'F', 'G', 'H', 'J', 'K', 'L'],
      ['⇧', 'Z', 'X', 'C', 'V', 'B', 'N', 'M', '⌫'],
    ];
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerHigh,
      elevation: 8,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 8, 4, 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final row in rows)
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (final key in row)
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.all(2),
                        child: Material(
                          color: Theme.of(
                            context,
                          ).colorScheme.surfaceContainerLowest,
                          borderRadius: BorderRadius.circular(5),
                          child: SizedBox(
                            height: 34,
                            child: Center(child: Text(key)),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            Row(
              children: [
                const Expanded(
                  flex: 4,
                  child: Padding(
                    padding: EdgeInsets.all(2),
                    child: Material(
                      child: SizedBox(
                        height: 34,
                        child: Center(child: Text('Space')),
                      ),
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Hide keyboard',
                  onPressed: () {
                    setState(() {
                      _showKeyboard = false;
                    });
                  },
                  icon: const Icon(Icons.keyboard_hide),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGestureHelp(BuildContext context) {
    return Material(
      color: Colors.black.withValues(alpha: 0.82),
      child: InkWell(
        onTap: () {
          setState(() {
            _showGestureHelp = false;
          });
        },
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.gesture, size: 72, color: Colors.white),
              const SizedBox(height: 16),
              Text(
                _touchMode ? 'Touch mode' : 'Mouse mode',
                style: Theme.of(
                  context,
                ).textTheme.headlineSmall?.copyWith(color: Colors.white),
              ),
              const SizedBox(height: 10),
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(
                    value: false,
                    icon: Icon(Icons.mouse),
                    label: Text('Mouse'),
                  ),
                  ButtonSegment(
                    value: true,
                    icon: Icon(Icons.touch_app),
                    label: Text('Touch'),
                  ),
                ],
                selected: {_touchMode},
                onSelectionChanged: (selection) {
                  setState(() {
                    _touchMode = selection.first;
                  });
                },
              ),
              const SizedBox(height: 10),
              const Text(
                'Drag to pan • wheel or pinch to zoom\nTap anywhere to close',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white70),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDisconnected(BuildContext context) {
    return ColoredBox(
      color: Colors.black.withValues(alpha: 0.78),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.link_off, size: 64, color: Colors.white70),
            const SizedBox(height: 12),
            Text(
              'Session disconnected',
              style: Theme.of(
                context,
              ).textTheme.titleLarge?.copyWith(color: Colors.white),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: () {
                setState(() {
                  _connected = true;
                });
              },
              icon: const Icon(Icons.refresh),
              label: const Text('Reconnect'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildConnecting(BuildContext context) {
    return ColoredBox(
      color: Colors.black.withValues(alpha: 0.78),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(color: Colors.white),
            const SizedBox(height: 16),
            Text(
              'Connecting to remote device…',
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(color: Colors.white),
            ),
          ],
        ),
      ),
    );
  }
}
