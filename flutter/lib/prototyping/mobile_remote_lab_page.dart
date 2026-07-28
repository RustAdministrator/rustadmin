import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
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

class MobileRemoteLabPage extends StatefulWidget {
  const MobileRemoteLabPage({
    super.key,
    required this.initialScreensDirectory,
    required this.themeMode,
    required this.onThemeModeChanged,
  });

  final String initialScreensDirectory;
  final ThemeMode themeMode;
  final ValueChanged<ThemeMode> onThemeModeChanged;

  @override
  State<MobileRemoteLabPage> createState() => _MobileRemoteLabPageState();
}

class _DevicePreset {
  const _DevicePreset(this.name, this.logicalSize, this.devicePixelRatio);

  final String name;
  final Size logicalSize;
  final double devicePixelRatio;
}

const _devicePresets = <_DevicePreset>[
  _DevicePreset('Redmi Note class', Size(393, 873), 2.75),
  _DevicePreset('Compact phone', Size(360, 800), 3),
  _DevicePreset('Large phone', Size(430, 932), 3),
  _DevicePreset('Small tablet', Size(800, 1280), 2),
];

class _MobileRemoteLabPageState extends State<MobileRemoteLabPage> {
  List<RemoteLabMonitor> _monitors = const [];
  _DevicePreset _devicePreset = _devicePresets.first;
  String _screensDirectory = '';
  String? _loadError;
  bool _portrait = true;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    unawaited(_loadInitialScreens());
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
          DropdownButtonFormField<_DevicePreset>(
            initialValue: _devicePreset,
            decoration: const InputDecoration(
              labelText: 'Device viewport',
              border: OutlineInputBorder(),
            ),
            items: _devicePresets
                .map(
                  (preset) =>
                      DropdownMenuItem(value: preset, child: Text(preset.name)),
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
                    width: viewport.width,
                    height: viewport.height,
                    child: MediaQuery(
                      data: MediaQueryData(
                        size: viewport,
                        devicePixelRatio: _devicePreset.devicePixelRatio,
                        textScaler: TextScaler.noScaling,
                        platformBrightness: Theme.of(context).brightness,
                      ),
                      child: MobileRemotePreview(monitors: _monitors),
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

enum _RemotePanel { displays, chat, more }

class MobileRemotePreview extends StatefulWidget {
  const MobileRemotePreview({super.key, required this.monitors});

  final List<RemoteLabMonitor> monitors;

  @override
  State<MobileRemotePreview> createState() => _MobileRemotePreviewState();
}

class _MobileRemotePreviewState extends State<MobileRemotePreview> {
  static const _allMonitors = -1;

  final TransformationController _transformationController =
      TransformationController();

  int _selectedMonitor = 0;
  bool _connected = true;
  bool _showToolbar = true;
  bool _showKeyboard = false;
  bool _touchMode = true;
  bool _showGestureHelp = false;
  _RemotePanel? _panel;

  @override
  void didUpdateWidget(covariant MobileRemotePreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_selectedMonitor >= widget.monitors.length) {
      _selectedMonitor = widget.monitors.isEmpty
          ? 0
          : widget.monitors.length - 1;
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
          if (!_connected) Positioned.fill(child: _buildDisconnected(context)),
          if (_showGestureHelp)
            Positioned.fill(child: _buildGestureHelp(context)),
          if (_showKeyboard && _connected)
            Align(
              alignment: Alignment.bottomCenter,
              child: _buildKeyboard(context),
            ),
          if (_panel != null) Positioned.fill(child: _buildPanel(context)),
        ],
      ),
      bottomNavigationBar: _showToolbar ? _buildBottomToolbar(context) : null,
      floatingActionButton: _showToolbar
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
    return Material(
      color: _accentColor,
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 56,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _toolbarButton(
                tooltip: _connected ? 'Disconnect' : 'Reconnect',
                icon: _connected ? Icons.close : Icons.refresh,
                onPressed: () {
                  setState(() {
                    _connected = !_connected;
                    _showKeyboard = false;
                    _panel = null;
                  });
                },
              ),
              _toolbarButton(
                tooltip: 'Displays',
                icon: Icons.tv,
                onPressed: widget.monitors.isEmpty
                    ? null
                    : () {
                        setState(() {
                          _panel = _RemotePanel.displays;
                        });
                      },
              ),
              _toolbarButton(
                tooltip: 'Keyboard',
                icon: Icons.keyboard,
                active: _showKeyboard,
                onPressed: _connected
                    ? () {
                        setState(() {
                          _showKeyboard = !_showKeyboard;
                          _panel = null;
                        });
                      }
                    : null,
              ),
              _toolbarButton(
                tooltip: _touchMode ? 'Touch mode' : 'Mouse mode',
                icon: _touchMode ? Icons.touch_app : Icons.mouse,
                onPressed: _connected
                    ? () {
                        setState(() {
                          _touchMode = !_touchMode;
                        });
                      }
                    : null,
              ),
              _toolbarButton(
                tooltip: 'Chat',
                icon: Icons.message,
                onPressed: _connected
                    ? () {
                        setState(() {
                          _panel = _RemotePanel.chat;
                        });
                      }
                    : null,
              ),
              _toolbarButton(
                tooltip: 'More',
                icon: Icons.more_vert,
                onPressed: () {
                  setState(() {
                    _panel = _RemotePanel.more;
                  });
                },
              ),
              _toolbarButton(
                tooltip: 'Hide toolbar',
                icon: Icons.expand_more,
                onPressed: () {
                  setState(() {
                    _showToolbar = false;
                    _panel = null;
                  });
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _toolbarButton({
    required String tooltip,
    required IconData icon,
    required VoidCallback? onPressed,
    bool active = false,
  }) {
    return Expanded(
      child: IconButton(
        tooltip: tooltip,
        color: active ? Colors.amberAccent : Colors.white,
        disabledColor: Colors.white38,
        onPressed: onPressed,
        icon: Icon(icon),
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
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 14, 20, 24),
                child: switch (_panel!) {
                  _RemotePanel.displays => _buildDisplayPanel(context),
                  _RemotePanel.chat => _buildChatPanel(context),
                  _RemotePanel.more => _buildMorePanel(context),
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDisplayPanel(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Displays', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (var index = 0; index < widget.monitors.length; index++)
              ChoiceChip(
                label: Text('Monitor ${index + 1}'),
                selected: _selectedMonitor == index,
                onSelected: (_) => _selectMonitor(index),
              ),
            if (widget.monitors.length > 1)
              ChoiceChip(
                label: const Text('All monitors'),
                selected: _selectedMonitor == _allMonitors,
                onSelected: (_) => _selectMonitor(_allMonitors),
              ),
          ],
        ),
      ],
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

  Widget _buildMorePanel(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Session controls',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.center_focus_strong),
          title: const Text('Reset view'),
          onTap: () {
            _resetView();
            setState(() {
              _panel = null;
            });
          },
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.gesture),
          title: const Text('Gesture help'),
          onTap: () {
            setState(() {
              _showGestureHelp = true;
              _panel = null;
            });
          },
        ),
      ],
    );
  }

  Widget _buildKeyboard(BuildContext context) {
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
}
