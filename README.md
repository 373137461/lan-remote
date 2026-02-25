# 局域网跨平台键鼠遥控器

用 iPhone 通过局域网远程控制 Windows / macOS 的鼠标和键盘，无需安装驱动，延迟极低。

## 架构

```
iPhone (Flutter iOS)  ──UDP 8888──►  Windows / macOS (Go)
       主控端                               被控端
```

| 端 | 技术 | 职责 |
| -- | ---- | ---- |
| 主控端 | Flutter iOS | 采集触摸 / 陀螺仪 / 键盘输入，封装 UDP 包发送 |
| 被控端 | Go + robotgo | 监听 UDP，解析指令，调用系统 API 驱动鼠标键盘；系统托盘 + 网页配置 |

---

## 快速开始

### 被控端（电脑）

**依赖**：Go 1.21+，macOS 需要 Xcode Command Line Tools

```bash
cd server
go build -o lan-remote-server .

# macOS
./lan-remote-server

# Windows
安装 MinGW-w64（如果没有 GCC）
推荐用 MSYS2 安装（最省事）：

下载安装 MSYS2，默认装在 C:\msys64

打开 MSYS2 UCRT64 终端，运行：

pacman -S mingw-w64-ucrt-x86_64-gcc
将 GCC 加入 Windows PATH：


C:\msys64\ucrt64\bin
（控制面板 → 系统 → 高级系统设置 → 环境变量 → Path → 新建）

set CGO_ENABLED=1
go build -o lan-remote-server.exe .
lan-remote-server.exe

# 可选参数
./lan-remote-server -port 9000 -timeout 80 -config /path/to/server.conf -log /path/to/ops.log
./lan-remote-server -nogui   # 无界面纯命令行模式
```

首次编译会拉取 `robotgo` 及其 C 依赖，需要几分钟。

> **macOS**：首次运行后，进入「系统设置 → 隐私与安全性 → 辅助功能」，勾选允许该程序，否则鼠标键盘控制不生效。

> **Windows**：如防火墙拦截，在「Windows Defender 防火墙 → 高级设置」中放行 UDP 8888 端口入站规则。

#### 系统托盘与网页配置

启动后会在系统托盘出现图标（默认 GUI 模式），右键托盘图标可：

- 查看当前端口和密码状态
- 打开**设置...**：用默认浏览器打开本地配置页（`http://127.0.0.1:<随机端口>`），在网页中修改密码、UDP 端口、超时阈值；密码和超时改动即时生效，端口改动需重启
- 切换**开机自启动**（macOS 写入 LaunchAgent plist，Windows 写入注册表启动项，Linux 写入 systemd user service）
- 退出程序

使用 `-nogui` 标志可跳过托盘，仅命令行运行（适合服务器、SSH 远程场景）。

#### 配置文件（server.conf）

程序目录下的 `server.conf` 支持以下选项（`key=value` 格式，`#` 开头为注释）：

```ini
# 连接密码（留空则免认证）
password=

# UDP 监听端口，默认 8888
port=8888

# 陈旧包丢弃阈值（毫秒），超过此值的包不执行，防止堆积指令乱飞
timeout=50

# 操作日志文件路径（留空则输出到控制台）
log_file=
```

---

### 主控端（iPhone）

**依赖**：Flutter 3.22+，Xcode 15+，真机运行需要 Apple 开发者账号

```bash
cd client
flutter pub get
flutter run --release   # 连接 iPhone 后运行
```

在连接界面输入被控电脑的**局域网 IP**（如 `192.168.1.100`），端口默认 8888，有密码则填写，点击「连接并同步时间」。

> 连接成功后会自动记住凭据，下次启动 App 自动重连。手动点击断开按钮则不触发自动重连。

---

## 功能详解

### 触摸板

| 手势 | 动作 |
|------|------|
| 单指滑动 | 鼠标指针移动 |
| 单指轻敲 | 左键单击 |
| 单指快速双敲（< 300ms）| 左键双击 |
| 单指长按（> 300ms）后滑动 | 按住左键拖拽，松开释放 |
| 双指轻敲 | 右键单击 |
| 右侧弹簧滑块上下拖动 | 鼠标滚轮（松手后弹回中位） |

顶部快捷按钮：左键 / 右键 / 中键 / 双击
底部大按钮：左键（支持长按拖拽）/ 右键

**灵敏度设置**（点击顶部「触摸板设置」展开）：
- 触控灵敏度：0.5 ~ 5.0，控制指针移动速度
- 滚轮灵敏度：0.3 ~ 4.0，控制滚轮每像素触发量

两项设置自动持久化，下次启动恢复。

---

### 空中飞鼠

竖持 iPhone，通过陀螺仪姿态控制鼠标：

| 动作 | 效果 |
|------|------|
| 左右转动手机 | 鼠标横向移动（偏航轴） |
| 前后倾斜手机 | 鼠标纵向移动（俯仰轴） |

**算法**：互补滤波（α = 0.95）融合陀螺仪 Z 轴积分与磁力计方位角，短期响应靠陀螺仪（平滑、低延迟），长期由磁力计修正偏航漂移。

- 顶部左键 / 右键按钮（大尺寸，左键支持长按拖拽）
- 发送频率节流至 60 Hz，避免网络拥塞

**控制面板**（默认折叠，点击展开）：
- 灵敏度：1 ~ 20，默认 8，自动持久化
- 启动 / 停止按钮

---

### 键盘

#### 快捷键面板

| 区域 | 包含按键 |
|------|----------|
| 控制键 | Esc、Tab、退格、Delete、Home、End、Page Up/Down |
| 方向键 | ↑ ↓ ← → |
| 功能键 | F1 ~ F12 |
| 媒体键 | 播放/暂停、上一首、下一首 |
| 音量控制 | 滑块（左右拖动，每格 = 1 次音量键），静音按钮 |

**编辑快捷键**（OS 自适应，macOS 用 Cmd，Windows 用 Ctrl）：

| 操作 | macOS | Windows |
|------|-------|---------|
| 全选 | Cmd+A | Ctrl+A |
| 复制 | Cmd+C | Ctrl+C |
| 剪切 | Cmd+X | Ctrl+X |
| 撤销 | Cmd+Z | Ctrl+Z |
| 重做 | Cmd+Shift+Z | Ctrl+Y |
| 保存 | Cmd+S | Ctrl+S |

**系统操作**（底部区域，OS 自适应）：

| 操作 | macOS | Windows |
|------|-------|---------|
| 切换应用 | Cmd+Tab | Alt+Tab |
| 任务视图 | Ctrl+↑（Mission Control） | Win+Tab |
| 显示桌面 | Ctrl+F3 | Win+D |
| 截图 | Cmd+Shift+3 | PrintScreen |
| 锁屏 | Ctrl+Cmd+Q | Win+L |
| 睡眠 | pmset sleepnow | 系统休眠 |
| 关机 | AppleScript shut down | shutdown /s（需确认） |
| 重启 | AppleScript restart | shutdown /r（需确认） |

关机 / 重启操作会弹出确认对话框，防止误触。

#### 文本发送面板

在多行文本框输入内容后点击「发送」，支持两种输入模式（模式自动持久化）：

| 模式 | 原理 | 适用场景 |
|------|------|----------|
| 剪贴板粘贴（默认） | 服务端写剪贴板 → 触发 Cmd/Ctrl+V | 速度快，支持中文、emoji、长文本 |
| 逐字输入 | 服务端调用 TypeStr 逐字符发送 | 不支持粘贴的输入框（如远程桌面、游戏） |

---

## 连接与心跳

1. **时间同步握手**：连接时客户端发送 `[0x00][密码长度][密码]`，服务端回复当前时间戳 + OS 标识 + 认证结果，客户端用 RTT / 2 补偿时钟偏差
2. **双向心跳**：连接后每 15 秒客户端发 Ping（`0x10` + 时间戳 8B），服务端回 Pong 并携带原始时间戳（客户端可计算 RTT）；客户端 45 秒未收到 Pong 自动断开并弹回连接页
3. **陈旧包丢弃**：服务端检查每个控制包时间戳，超过阈值（默认 50ms）的包直接丢弃，防止网络抖动堆积指令

---

## UDP 协议

大端序，通用格式：`[Cmd 1B] + [Timestamp 8B] + [Payload N B]`

| 指令 | Cmd | Payload 格式 | 说明 |
|------|-----|-------------|------|
| 时间同步 | `0x00` | `[pwd_len 1B][password N B]` | 握手，服务端回 `[0x00][time 8B][os 1B][auth 1B]` |
| 鼠标移动 | `0x01` | `dx(Int16) + dy(Int16)` | 相对位移，像素 |
| 鼠标点击 | `0x02` | `button(UInt8)` | 0=左,1=右,2=中 |
| 鼠标滚轮 | `0x03` | `delta(Int16)` | 正=上滚,负=下滚 |
| 单键敲击 | `0x04` | `keycode(UInt8)` | 见键码表 |
| 文本(剪贴板) | `0x05` | `len(UInt16) + UTF-8` | 写剪贴板后触发 Cmd/Ctrl+V |
| 鼠标按下 | `0x06` | `button(UInt8)` | 拖拽开始 |
| 鼠标松开 | `0x07` | `button(UInt8)` | 拖拽结束 |
| 双击 | `0x08` | `button(UInt8)` | |
| 文本(逐字) | `0x09` | `len(UInt16) + UTF-8` | TypeStr 直接输入，不经剪贴板 |
| 系统操作 | `0x0A` | `action(UInt8)` | 见系统操作码 |
| 心跳 Ping | `0x10` | `[timestamp 8B]`（可选） | 服务端回同样格式；旧格式仅 1 字节 |

**时间同步响应 OS 标识**：`0x00`=Windows，`0x01`=macOS，`0x02`=Linux

**系统操作码**：

| 码 | 操作 |
| -- | ---- |
| `0x01` | 锁屏 |
| `0x02` | 睡眠 |
| `0x03` | 关机 |
| `0x04` | 重启 |
| `0x05` | 切换应用（Cmd/Alt+Tab） |
| `0x06` | 截图 |
| `0x07` | 全选（Cmd/Ctrl+A） |
| `0x08` | 复制（Cmd/Ctrl+C） |
| `0x09` | 剪切（Cmd/Ctrl+X） |
| `0x0A` | 撤销（Cmd/Ctrl+Z） |
| `0x0B` | 重做（Cmd+Shift+Z / Ctrl+Y） |
| `0x0C` | 保存（Cmd/Ctrl+S） |
| `0x0D` | 任务视图（Ctrl+↑ / Win+Tab） |
| `0x0E` | 显示桌面（Ctrl+F3 / Win+D） |

---

## 项目结构

```
.
├── server/
│   ├── main.go              # UDP 监听、指令分发、robotgo 执行、系统操作
│   ├── tray.go              # 系统托盘（fyne.io/systray）
│   ├── webconfig.go         # 本地 HTTP 配置服务 + 内嵌网页
│   ├── autostart_darwin.go  # macOS LaunchAgent 自启动
│   ├── autostart_windows.go # Windows 注册表自启动
│   ├── autostart_linux.go   # Linux systemd user service 自启动
│   ├── assets/
│   │   └── app_icon.png     # 托盘图标（编译期嵌入）
│   ├── server.conf          # 运行时配置（密码、端口、超时、日志）
│   ├── go.mod
│   └── go.sum
└── client/
    ├── pubspec.yaml
    └── lib/
        ├── main.dart                        # App 入口、主题
        ├── services/
        │   └── udp_service.dart             # UDP 通信、时间同步、心跳、断开通知流
        ├── screens/
        │   ├── connection_screen.dart       # 连接页（自动重连、凭据持久化）
        │   ├── control_screen.dart          # Tab 框架（显示 OS 名、监听断开事件）
        │   ├── touchpad_screen.dart         # 触摸板（手势、灵敏度、弹簧滚轮）
        │   ├── gyro_screen.dart             # 空中飞鼠（互补滤波、折叠控制面板）
        │   └── keyboard_screen.dart         # 键盘（快捷键、音量、系统操作、文本发送）
        ├── widgets/
        │   └── collapse_card.dart           # 可折叠卡片组件
        └── utils/
            └── keycodes.dart                # 按键码映射表
```

---

## 依赖

### 被控端

| 包 | 用途 |
| -- | ---- |
| `github.com/go-vgo/robotgo` | 跨平台鼠标键盘控制 |
| `fyne.io/systray` | 跨平台系统托盘（轻量，无 GUI 框架依赖） |

### 主控端

| 包 | 用途 |
|----|------|
| `sensors_plus` | 陀螺仪、磁力计传感器 |
| `shared_preferences` | 本地持久化（凭据、灵敏度、输入模式） |

---

## 常见问题

**Q: macOS 上鼠标/键盘没有响应？**
A: 前往「系统设置 → 隐私与安全性 → 辅助功能」，添加并勾选 `lan-remote-server`。

**Q: 粘贴模式只打出了字母 v？**
A: 同上，辅助功能权限未授予时 `KeyDown("command")` 无效。授权后重新测试。

**Q: 连接超时 / 找不到设备？**
A: 确认手机和电脑在**同一 Wi-Fi** 下，且服务端正在运行。部分路由器开启了 AP 隔离，需在路由器设置中关闭。

**Q: 陀螺仪飞鼠左右方向漂移？**
A: 磁力计初始化需要 1~2 秒，启动后稍等片刻再移动。若持续漂移，可在远离金属干扰的环境下使用。

**Q: 如何设置密码？**
A: 点击托盘图标 → 「设置...」，浏览器会打开本地配置页，修改密码后点「保存」即时生效。也可直接编辑 `server.conf` 中的 `password=` 字段后重启。

**Q: 想更改监听端口？**
A: 点击托盘图标 → 「设置...」，在网页中修改端口后保存，**需重启服务端**生效。主控端连接界面的「端口」字段同步修改。

**Q: 如何设置开机自启动？**
A: 点击托盘图标 → 「开机自启动」切换开关即可。macOS 通过 LaunchAgent 实现，Windows 写入注册表 `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`，Linux 生成 systemd user service。

**Q: 服务器环境没有图形界面怎么办？**
A: 使用 `-nogui` 参数启动，跳过托盘和网页配置服务，仅命令行运行：`./lan-remote-server -nogui`。

---

## 关于本项目

本程序**全程由 AI 辅助编写**，从零到可用历时约 **1 小时**。

代码完全开源，任何人均可自由：

- 使用、修改、二次开发
- 提交 Pull Request 改进功能或修复 Bug
- Fork 后按需定制

欢迎贡献！
