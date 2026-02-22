/// 与服务端 keyMap 对应的按键码定义
class KeyCodes {
  // 基础控制键
  static const int enter = 13;
  static const int backspace = 8;
  static const int escape = 27;
  static const int tab = 9;
  static const int space = 32;

  // 方向键
  static const int arrowLeft = 37;
  static const int arrowUp = 38;
  static const int arrowRight = 39;
  static const int arrowDown = 40;

  // 导航键
  static const int delete = 46;
  static const int home = 36;
  static const int end = 35;
  static const int pageUp = 33;
  static const int pageDown = 34;

  // 功能键
  static const int f1 = 112;
  static const int f2 = 113;
  static const int f3 = 114;
  static const int f4 = 115;
  static const int f5 = 116;
  static const int f6 = 117;
  static const int f7 = 118;
  static const int f8 = 119;
  static const int f9 = 120;
  static const int f10 = 121;
  static const int f11 = 122;
  static const int f12 = 123;

  // 媒体键（自定义扩展码 >= 200）
  static const int volUp = 200;
  static const int volDown = 201;
  static const int mute = 202;
  static const int playPause = 203;
  static const int nextTrack = 204;
  static const int prevTrack = 205;
}

/// 快捷键面板的按钮数据模型
class KeyButton {
  final String label;
  final int keycode;
  final String icon;

  const KeyButton({
    required this.label,
    required this.keycode,
    this.icon = '',
  });
}

/// 预定义的按键面板布局
const List<List<KeyButton>> keyboardLayout = [
  // 第一行：常用控制
  [
    KeyButton(label: 'Esc', keycode: KeyCodes.escape, icon: '⎋'),
    KeyButton(label: 'Tab', keycode: KeyCodes.tab, icon: '⇥'),
    KeyButton(label: '⌫', keycode: KeyCodes.backspace, icon: '⌫'),
    KeyButton(label: 'Del', keycode: KeyCodes.delete, icon: '⌦'),
    KeyButton(label: '↵', keycode: KeyCodes.enter, icon: '↵'),
  ],
  // 第二行：方向键
  [
    KeyButton(label: 'Home', keycode: KeyCodes.home, icon: '↖'),
    KeyButton(label: '↑', keycode: KeyCodes.arrowUp, icon: '↑'),
    KeyButton(label: 'End', keycode: KeyCodes.end, icon: '↘'),
    KeyButton(label: 'PgUp', keycode: KeyCodes.pageUp, icon: '⇑'),
    KeyButton(label: 'PgDn', keycode: KeyCodes.pageDown, icon: '⇓'),
  ],
  // 第三行：方向键（主要）
  [
    KeyButton(label: '←', keycode: KeyCodes.arrowLeft, icon: '←'),
    KeyButton(label: '↓', keycode: KeyCodes.arrowDown, icon: '↓'),
    KeyButton(label: '→', keycode: KeyCodes.arrowRight, icon: '→'),
    KeyButton(label: 'F11', keycode: KeyCodes.f11, icon: ''),
    KeyButton(label: 'F12', keycode: KeyCodes.f12, icon: ''),
  ],
  // 第四行：媒体控制
  [
    KeyButton(label: '⏮', keycode: KeyCodes.prevTrack, icon: '⏮'),
    KeyButton(label: '⏯', keycode: KeyCodes.playPause, icon: '⏯'),
    KeyButton(label: '⏭', keycode: KeyCodes.nextTrack, icon: '⏭'),
    KeyButton(label: '🔇', keycode: KeyCodes.mute, icon: '🔇'),
    KeyButton(label: '🔊', keycode: KeyCodes.volUp, icon: '🔊'),
  ],
];
