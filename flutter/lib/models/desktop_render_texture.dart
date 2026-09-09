import 'package:flutter/material.dart';
import 'package:flutter_gpu_texture_renderer/flutter_gpu_texture_renderer.dart';
import 'package:flutter_hbb/common/shared_state.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/models/model.dart';
import 'package:flutter_hbb/models/render_target_lifecycle.dart';
import 'package:get/get.dart';

import '../../common.dart';
import './platform_model.dart';

import 'package:texture_rgba_renderer/texture_rgba_renderer.dart'
    if (dart.library.html) 'package:flutter_hbb/web/texture_rgba_renderer.dart';

class _PixelbufferTexture {
  int _textureKey = -1;
  int _display = 0;
  SessionID? _sessionId;
  int? _id;
  int? _ptr;
  int _token = 0;
  bool _registered = false;
  final RenderTargetLifecycle _lifecycle = RenderTargetLifecycle();

  final textureRenderer = TextureRgbaRenderer();

  int get display => _display;

  void create(int d, SessionID sessionId, FFI ffi) {
    _display = d;
    _textureKey = bind.getNextTextureKey();
    _token = platformFFI.nextRenderTargetToken();
    _sessionId = sessionId;
    _lifecycle.trackCreation(_create(d, sessionId, ffi));
  }

  Future<void> _create(int d, SessionID sessionId, FFI ffi) async {
    try {
      final id = await textureRenderer.createTexture(_textureKey);
      _id = id;
      if (id != -1) {
        final ptr = await textureRenderer.getTexturePtr(_textureKey);
        _ptr = ptr;
        if (!_lifecycle.mayRegister) return;
        ffi.textureModel.setRgbaTextureId(display: d, id: id);
        platformFFI.registerPixelbufferRenderTarget(
          sessionId,
          display,
          ptr,
          _token,
        );
        _registered = true;
        debugPrint(
          "create pixelbuffer texture: peerId: ${ffi.id} display:$_display, textureId:$id, texturePtr:$ptr, token:$_token",
        );
      }
    } catch (err) {
      debugPrint('Failed to create pixelbuffer texture: $err');
    }
  }

  Future<void> destroy(FFI ffi) => _lifecycle.retire(() async {
    if (_registered && _sessionId != null) {
      platformFFI.unregisterPixelbufferRenderTarget(
        _sessionId!,
        display,
        _token,
      );
      _registered = false;
      await Future.delayed(const Duration(milliseconds: 100));
    }
    if (_textureKey == -1) return;
    await textureRenderer.closeTexture(_textureKey);
    _textureKey = -1;
    debugPrint(
      "destroy pixelbuffer texture: peerId: ${ffi.id} display:$_display, textureId:$_id, texturePtr:$_ptr, token:$_token",
    );
  });
}

class _GpuTexture {
  int _textureId = -1;
  SessionID? _sessionId;
  final support = bind.mainHasGpuTextureRender();
  int _display = 0;
  int? _id;
  int? _output;
  int _token = 0;
  bool _registered = false;
  final RenderTargetLifecycle _lifecycle = RenderTargetLifecycle();

  int get display => _display;

  final gpuTextureRenderer = FlutterGpuTextureRenderer();

  _GpuTexture();

  void create(int d, SessionID sessionId, FFI ffi) {
    if (support) {
      _sessionId = sessionId;
      _display = d;
      _token = platformFFI.nextRenderTargetToken();
      _lifecycle.trackCreation(_create(d, sessionId, ffi));
    }
  }

  Future<void> _create(int d, SessionID sessionId, FFI ffi) async {
    try {
      final id = await gpuTextureRenderer.registerTexture();
      _id = id;
      if (id != null) {
        _textureId = id;
        final output = await gpuTextureRenderer.output(id);
        _output = output;
        if (output == null || !_lifecycle.mayRegister) return;
        ffi.textureModel.setGpuTextureId(display: d, id: id);
        platformFFI.registerGpuRenderTarget(sessionId, d, output, _token);
        _registered = true;
        debugPrint(
          "create gpu texture: peerId: ${ffi.id} display:$_display, textureId:$id, output:$output, token:$_token",
        );
      }
    } catch (err) {
      debugPrint("Failed to register gpu texture: $err");
    }
  }

  Future<void> destroy(FFI ffi) => _lifecycle.retire(() async {
    if (!support) return;
    if (_registered && _sessionId != null) {
      platformFFI.unregisterGpuRenderTarget(_sessionId!, _display, _token);
      _registered = false;
      await Future.delayed(const Duration(milliseconds: 100));
    }
    if (_textureId == -1) return;
    await gpuTextureRenderer.unregisterTexture(_textureId);
    _textureId = -1;
    debugPrint(
      "destroy gpu texture: peerId: ${ffi.id} display:$_display, textureId:$_id, output:$_output, token:$_token",
    );
  });
}

class _Control {
  RxInt textureID = (-1).obs;

  int _rgbaTextureId = -1;
  int get rgbaTextureId => _rgbaTextureId;
  int _gpuTextureId = -1;
  int get gpuTextureId => _gpuTextureId;
  bool _isGpuTexture = false;
  bool get isGpuTexture => _isGpuTexture;

  setTextureType({bool gpuTexture = false}) {
    _isGpuTexture = gpuTexture;
    textureID.value = _isGpuTexture ? gpuTextureId : rgbaTextureId;
  }

  setRgbaTextureId(int id) {
    _rgbaTextureId = id;
    textureID.value = _isGpuTexture ? gpuTextureId : rgbaTextureId;
  }

  setGpuTextureId(int id) {
    _gpuTextureId = id;
    textureID.value = _isGpuTexture ? gpuTextureId : rgbaTextureId;
  }
}

class TextureModel {
  final WeakReference<FFI> parent;
  final Map<int, _Control> _control = {};
  final Map<int, _PixelbufferTexture> _pixelbufferRenderTextures = {};
  final Map<int, _GpuTexture> _gpuRenderTextures = {};
  bool _screenViewAllowed = true;
  Future<void>? _screenRetirement;

  void setScreenViewAllowed(bool allowed) {
    _screenViewAllowed = allowed;
    final ffi = parent.target;
    if (ffi == null) return;
    if (!allowed) {
      // Publish the empty target before awaiting native teardown. Keep the Rx
      // objects so existing widgets observe both removal and replacement.
      for (final control in _control.values) {
        control.setRgbaTextureId(-1);
        control.setGpuTextureId(-1);
      }
      final previous = _screenRetirement;
      final current = _destroyAll(ffi, keepControls: true);
      _screenRetirement = Future.wait<void>([
        if (previous != null) previous,
        current,
      ]).then<void>((_) {}, onError: (Object error, StackTrace stackTrace) {
        debugPrint('Screen target retirement failed: $error\n$stackTrace');
      });
    } else if (isDesktop) {
      final epoch = ffi.screenViewAuthority.epoch;
      final retirement = _screenRetirement ?? Future<void>.value();
      retirement.then((_) {
        if (_screenViewAllowed && ffi.screenViewAuthority.accepts(epoch)) {
          updateCurrentDisplay(ffi.ffiModel.pi.currentDisplay);
        }
      });
    }
  }

  TextureModel(this.parent);

  setTextureType({required int display, required bool gpuTexture}) {
    if (!_screenViewAllowed) return;
    debugPrint("setTextureType: display=$display, isGpuTexture=$gpuTexture");
    ensureControl(display);
    _control[display]?.setTextureType(gpuTexture: gpuTexture);
    // For versions that do not support multiple displays, the display parameter is always 0, need set type of current display
    final ffi = parent.target;
    if (ffi == null) return;
    if (!ffi.ffiModel.pi.isSupportMultiDisplay) {
      final currentDisplay = CurrentDisplayState.find(ffi.id).value;
      if (currentDisplay != display) {
        debugPrint(
          "setTextureType: currentDisplay=$currentDisplay, isGpuTexture=$gpuTexture",
        );
        ensureControl(currentDisplay);
        _control[currentDisplay]?.setTextureType(gpuTexture: gpuTexture);
      }
    }
  }

  setRgbaTextureId({required int display, required int id}) {
    if (!_screenViewAllowed) return;
    ensureControl(display);
    _control[display]?.setRgbaTextureId(id);
  }

  setGpuTextureId({required int display, required int id}) {
    if (!_screenViewAllowed) return;
    ensureControl(display);
    _control[display]?.setGpuTextureId(id);
  }

  RxInt getTextureId(int display) {
    ensureControl(display);
    return _control[display]!.textureID;
  }

  updateCurrentDisplay(int curDisplay) {
    if (isWeb || !_screenViewAllowed) return;
    final ffi = parent.target;
    if (ffi == null) return;
    tryCreateTexture(int idx) {
      if (!_pixelbufferRenderTextures.containsKey(idx)) {
        final renderTexture = _PixelbufferTexture();
        _pixelbufferRenderTextures[idx] = renderTexture;
        renderTexture.create(idx, ffi.sessionId, ffi);
      }
      if (!_gpuRenderTextures.containsKey(idx)) {
        final renderTexture = _GpuTexture();
        _gpuRenderTextures[idx] = renderTexture;
        renderTexture.create(idx, ffi.sessionId, ffi);
      }
    }

    tryRemoveTexture(int idx) {
      _control.remove(idx);
      if (_pixelbufferRenderTextures.containsKey(idx)) {
        _pixelbufferRenderTextures[idx]!.destroy(ffi);
        _pixelbufferRenderTextures.remove(idx);
      }
      if (_gpuRenderTextures.containsKey(idx)) {
        _gpuRenderTextures[idx]!.destroy(ffi);
        _gpuRenderTextures.remove(idx);
      }
    }

    if (curDisplay == kAllDisplayValue) {
      final displays = ffi.ffiModel.pi.getCurDisplays();
      for (var i = 0; i < displays.length; i++) {
        tryCreateTexture(i);
      }
    } else {
      tryCreateTexture(curDisplay);
      for (var i = 0; i < ffi.ffiModel.pi.displays.length; i++) {
        if (i != curDisplay) {
          tryRemoveTexture(i);
        }
      }
    }
  }

  onRemotePageDispose(bool closeSession) async {
    final ffi = parent.target;
    if (ffi == null) return;
    await _destroyAll(ffi);
  }

  resetForSessionRestart() async {
    final ffi = parent.target;
    if (ffi == null) return;
    await _destroyAll(ffi);
  }

  onViewCameraPageDispose(bool closeSession) async {
    final ffi = parent.target;
    if (ffi == null) return;
    await _destroyAll(ffi);
  }

  Future<void> _destroyAll(FFI ffi, {bool keepControls = false}) async {
    final textures = <Future<void>>[
      ..._pixelbufferRenderTextures.values.map(
        (texture) => texture.destroy(ffi),
      ),
      ..._gpuRenderTextures.values.map((texture) => texture.destroy(ffi)),
    ];
    _pixelbufferRenderTextures.clear();
    _gpuRenderTextures.clear();
    if (!keepControls) _control.clear();
    await Future.wait(textures);
  }

  ensureControl(int display) {
    var ctl = _control[display];
    if (ctl == null) {
      ctl = _Control();
      _control[display] = ctl;
    }
  }
}
