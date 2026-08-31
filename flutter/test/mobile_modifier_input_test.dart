import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/generated_bridge.dart';
import 'package:flutter_hbb/mobile/mobile_modifier_state.dart';
import 'package:flutter_hbb/models/input_model.dart';
import 'package:flutter_hbb/models/model.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_test/flutter_test.dart';

class _InputKeyCall {
  const _InputKeyCall({
    required this.name,
    required this.down,
    required this.press,
    required this.alt,
    required this.ctrl,
    required this.shift,
    required this.command,
  });

  final String name;
  final bool down;
  final bool press;
  final bool alt;
  final bool ctrl;
  final bool shift;
  final bool command;
}

class _TestRustadminImpl implements Rustadmin {
  final inputKeyCalls = <_InputKeyCall>[];

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #translate) {
      return invocation.namedArguments[#name] as String;
    }
    if (invocation.memberName == #mainGetLocalOption ||
        invocation.memberName == #mainGetUserDefaultOption ||
        invocation.memberName == #getLocalFlutterOption ||
        invocation.memberName == #mainSupportedInputSource ||
        invocation.memberName == #mainGetDisplays) {
      return '';
    }
    if (invocation.memberName == #isDisableAb ||
        invocation.memberName == #isDisableAccount ||
        invocation.memberName == #isDisableGroupPanel ||
        invocation.memberName == #mainCurrentIsWayland ||
        invocation.memberName == #mainHasFileClipboard ||
        invocation.memberName == #sessionGetToggleOptionSync) {
      return false;
    }
    if (invocation.memberName == #sessionInputKey) {
      inputKeyCalls.add(
        _InputKeyCall(
          name: invocation.namedArguments[#name] as String,
          down: invocation.namedArguments[#down] as bool,
          press: invocation.namedArguments[#press] as bool,
          alt: invocation.namedArguments[#alt] as bool,
          ctrl: invocation.namedArguments[#ctrl] as bool,
          shift: invocation.namedArguments[#shift] as bool,
          command: invocation.namedArguments[#command] as bool,
        ),
      );
      return Future<void>.value();
    }
    if (invocation.memberName == #sessionSendMouse) {
      return Future<void>.value();
    }
    return super.noSuchMethod(invocation);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _TestRustadminImpl testImpl;
  late InputModel inputModel;

  setUpAll(() {
    isTest = true;
    testImpl = _TestRustadminImpl();
    platformFFI.initForTest(testImpl);
  });

  setUp(() {
    testImpl.inputKeyCalls.clear();
    inputModel = (FFI(null)..id = 'mobile-modifier-test-peer').inputModel;
  });

  tearDown(() {
    inputModel.disposeRelativeMouseMode();
  });

  test('one-shot Ctrl is explicitly released after Ctrl+A', () {
    inputModel.mobileModifierState.tap(MobileModifierKey.ctrl);

    inputModel.inputKey('VK_A');

    expect(inputModel.ctrl, isFalse);
    expect(
      inputModel.mobileModifierState.modeFor(MobileModifierKey.ctrl),
      MobileModifierMode.off,
    );
    expect(testImpl.inputKeyCalls, hasLength(2));
    expect(testImpl.inputKeyCalls[0].name, 'VK_A');
    expect(testImpl.inputKeyCalls[0].press, isTrue);
    expect(testImpl.inputKeyCalls[0].ctrl, isTrue);
    expect(testImpl.inputKeyCalls[1].name, 'VK_CONTROL');
    expect(testImpl.inputKeyCalls[1].down, isFalse);
    expect(testImpl.inputKeyCalls[1].press, isFalse);
    expect(testImpl.inputKeyCalls[1].ctrl, isFalse);
  });

  test('one-shot release preserves a locked modifier', () {
    inputModel.mobileModifierState.tap(MobileModifierKey.ctrl);
    inputModel.mobileModifierState.lock(MobileModifierKey.shift);

    inputModel.inputKey('VK_A');

    expect(inputModel.ctrl, isFalse);
    expect(inputModel.shift, isTrue);
    expect(testImpl.inputKeyCalls, hasLength(2));
    expect(testImpl.inputKeyCalls[0].ctrl, isTrue);
    expect(testImpl.inputKeyCalls[0].shift, isTrue);
    expect(testImpl.inputKeyCalls[1].name, 'VK_CONTROL');
    expect(testImpl.inputKeyCalls[1].shift, isTrue);
  });

  test('locked modifiers are not released after ordinary input', () {
    inputModel.mobileModifierState.lock(MobileModifierKey.ctrl);

    inputModel.inputKey('VK_A');

    expect(inputModel.ctrl, isTrue);
    expect(testImpl.inputKeyCalls, hasLength(1));
    expect(testImpl.inputKeyCalls.single.ctrl, isTrue);
  });

  test('turning off a modifier sends its key-up immediately', () {
    inputModel.mobileModifierState.lock(MobileModifierKey.ctrl);
    testImpl.inputKeyCalls.clear();

    inputModel.mobileModifierState.tap(MobileModifierKey.ctrl);

    expect(inputModel.ctrl, isFalse);
    expect(testImpl.inputKeyCalls, hasLength(1));
    expect(testImpl.inputKeyCalls.single.name, 'VK_CONTROL');
    expect(testImpl.inputKeyCalls.single.down, isFalse);
    expect(testImpl.inputKeyCalls.single.press, isFalse);
  });

  test('temporary shortcut modifiers are explicitly released', () {
    inputModel.inputKeyWithTemporaryMobileModifier(
      'VK_C',
      MobileModifierKey.ctrl,
    );

    expect(inputModel.ctrl, isFalse);
    expect(testImpl.inputKeyCalls, hasLength(2));
    expect(testImpl.inputKeyCalls[0].name, 'VK_C');
    expect(testImpl.inputKeyCalls[0].ctrl, isTrue);
    expect(testImpl.inputKeyCalls[1].name, 'VK_CONTROL');
    expect(testImpl.inputKeyCalls[1].ctrl, isFalse);
  });
}
