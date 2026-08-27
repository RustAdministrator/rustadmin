# Mobile gestures

The table records the gestures currently supported on the remote-session
screen. “Mouse mode” moves a remote cursor relatively, like a trackpad.
“Touch mode” maps the local gesture position directly onto the remote screen.

| Area | Gesture | Mouse mode | Touch mode | Notes |
|---|---|---|---|---|
| Remote screen | One-finger tap | Left click at the current remote cursor | Move to the tap position and left click | A tap on a floating control is consumed by that control. |
| Remote screen | One-finger tap and hold | Left button down; release sends left button up | Move to the hold position and hold the left button; release sends left button up | Moving after the hold starts performs a left-button drag. |
| Remote screen | One-finger drag | Move the remote cursor | Move to the finger, hold the left button, and drag | Mouse-mode release velocity continues briefly when cursor inertia is enabled. |
| Remote screen | Double tap | Double left click at the current remote cursor | Move to the tap position and double left click | Two clicks are sent as separate left-click sequences. |
| Remote screen | Double tap, then drag | Hold the left button and drag the remote cursor | Not used; a normal one-finger drag already performs a direct left drag | This is the legacy mouse-mode drag gesture. |
| Remote screen | Two-finger tap | Right click at the current remote cursor | Move to the midpoint of both fingers and right click | Both fingers must stay within tap tolerance. |
| Remote screen | Two-finger tap and hold | Hold the right button; releasing either finger sends right button up | Move to the midpoint of both fingers and hold the right button; releasing either finger sends right button up | Moving beyond tap tolerance before the hold starts changes the gesture into wheel, local pan, or zoom according to its direction. |
| Remote screen | Two-finger vertical drag | Remote mouse wheel | Remote mouse wheel | Predominantly vertical parallel movement is committed to wheel scrolling until both fingers are released. It does not move the remote cursor or local canvas. |
| Remote screen | Two-finger horizontal/diagonal drag | Pan the local view of the remote screen | Pan the local view of the remote screen | Movement that is not predominantly vertical pans locally and does not send a remote mouse event. |
| Remote screen | Two-finger pinch or spread | Zoom the local view of the remote screen | Zoom the local view of the remote screen | Zoom is clamped by the mobile viewport rules. |
| Remote screen | Three-finger vertical drag | Remote mouse wheel | Remote mouse wheel | Disabled for Android peers, where this gesture is not forwarded as a wheel. |
| Virtual left/right button | Quick tap | Send the corresponding mouse click | Send the corresponding mouse click | Applies when the optional virtual mouse controls are visible. |
| Virtual left/right button | Press and hold | Hold the corresponding remote mouse button until release | Hold the corresponding remote mouse button until release | While held in mouse mode, another-finger movement drags the remote cursor with that button down. |
| Virtual joystick | Drag away from center | Move the remote cursor continuously in that direction | Not shown | Releasing the joystick stops movement. Relative mode sends motion deltas directly. |
| Floating toolbar | Drag | Reposition the toolbar | Reposition the toolbar | This UI gesture is consumed locally and does not move the remote cursor. |
| Custom-key strip | Horizontal drag | Scroll the custom-key row | Scroll the custom-key row | The drag is consumed locally and does not pan the remote screen or move the remote cursor. |
| Custom non-modifier key | Tap | Send that key or shortcut | Send that key or shortcut | All one-shot modifiers are disabled after the key is sent; locked modifiers remain active. |
| Custom modifier key | Tap | Arm or disable the modifier | Arm or disable the modifier | An armed modifier uses the normal active color, combines with other modifiers, and is consumed by the next non-modifier key. Tapping the same modifier again disables it. |
| Custom modifier key | Double tap | Lock the modifier | Lock the modifier | A locked modifier uses a blue background and remains active until it is tapped once. |

## Mobile keyboard input and custom arrow keys

For a modern non-Android peer, a new peer configuration selects `map` as the
keyboard mode. It falls back to `legacy` when map mode is not supported;
Android peers therefore use legacy mode. Translate mode is selectable when the
peer supports it, but is not selected by default. The mode primarily affects a
physical keyboard. Soft-keyboard text uses the text-input packet path, and
custom buttons send named legacy control keys.

| Custom button | Sent key name | Protocol control key |
|---|---|---|
| Left arrow | `VK_LEFT` | `LeftArrow` |
| Up arrow | `VK_UP` | `UpArrow` |
| Down arrow | `VK_DOWN` | `DownArrow` |
| Right arrow | `VK_RIGHT` | `RightArrow` |

The toolbar is normally opaque. When the current local/remote cursor point is
inside the toolbar rectangle, it immediately uses the configured “Toolbar
opacity under cursor” value (20% by default); it becomes opaque immediately
when the cursor leaves. Setting the value to 100% disables this transparency.

Cursor inertia applies only to one-finger cursor movement in mouse mode. The
configured time controls a linear slowdown after the finger is released. It is
set with the `100-1000 ms` slider inside the `Screen scrolling` menu. A new
touch, click, hold, or multi-finger gesture stops the active inertia
immediately.

## Saved mobile session controls

- The floating toolbar saves its horizontal/vertical layout and normalized
  screen position. Opening the keyboard hides the toolbar without discarding
  that state, so closing the keyboard restores the same layout and position.
- Mouse/Touch mode is saved as a device-local preference. Screen scrolling,
  edge size, cursor inertia, and toolbar opacity are saved in the peer/session
  configuration and restored on the next connection.
- `Show monitors in toolbar` is available under the toolbar's Display and
  session options when the peer exposes multiple displays, and as a global
  default under Display Settings. The preference is saved, and the enabled
  toolbar shows direct monitor buttons plus the combined display button when
  supported.
