# 局域网跨平台键鼠遥控器

用 iPhone 通过局域网远程控制 Windows / macOS 的鼠标和键盘，无需安装驱动，延迟极低。

## 架构

```text
iPhone (Flutter iOS)  ──UDP 8888──►  Windows / macOS (Go)
       主控端                               被控端
```

| 端 | 技术 | 职责 |
| -- | ---- | ---- |
| 主控端 | Flutter iOS | 采集触摸 / 陀螺仪 / 键盘输入，封装 UDP 包发送 |
| 被控端 | Go + robotgo | 监听 UDP，解析指令，调用系统 API 驱动鼠标键盘；系统托盘 + 网页配置 |

> **Windows 亮点**：支持以 **系统服务（SYSTEM 权限）** 方式运行，可在系统启动时自动监听，并在 **登录界面（Winlogon 桌面）** 直接注入鼠标和键盘输入，实现远程输入开机密码。

---

## 快速开始

### 被控端（电脑）

**依赖**：Go 1.21+，macOS 需要 Xcode Command Line Tools

```bash
cd server

# macOS Release 构建（去掉调试符号，体积减半）
go build -ldflags="-s -w" -trimpath -o lan-remote-server .
./lan-remote-server          # 默认：GUI 模式（系统托盘 + 网页配置）
./lan-remote-server -nogui   # 纯命令行模式（服务器 / SSH 场景）

# Windows（需先安装 MinGW-w64 / MSYS2，并将 GCC 加入 PATH）
set CGO_ENABLED=1
go build -ldflags="-s -w -H windowsgui" -trimpath -o lan-remote-server.exe .
lan-remote-server.exe        # 默认 GUI 模式，不弹命令行窗口

# 进一步压缩二进制（需先安装 UPX：brew install upx / upx.github.io）
upx --best lan-remote-server          # macOS
upx --best lan-remote-server.exe      # Windows

# 可选启动参数
./lan-remote-server -port 9000 -timeout 80 -config /path/to/server.conf -log /path/to/ops.log
```

首次编译会拉取 `robotgo` 及其 C 依赖，需要几分钟。

> **macOS**：首次运行后，进入「系统设置 → 隐私与安全性 → 辅助功能」，勾选允许该程序，否则鼠标键盘控制不生效。
>
> **Windows**：如防火墙拦截，在「Windows Defender 防火墙 → 高级设置」中放行 UDP 8888 端口入站规则。

#### 系统托盘与网页配置

启动后系统托盘出现图标（默认 GUI 模式），右键可：

- 查看当前端口和密码状态
- 打开**设置...**：用默认浏览器打开本地配置页（`http://127.0.0.1:<随机端口>`），在网页中修改密码、UDP 端口、超时阈值、**自定义快捷键**，并实时查看**已连接设备**；**所有修改保存后立即生效**（含端口切换，无需重启）
- 切换**开机自启动**（macOS 写入 LaunchAgent plist，Windows 写入注册表启动项，Linux 写入 systemd user service）
- **Windows 专属**：**安装为系统服务** / **卸载系统服务**（见下节）
- 退出程序

Windows 下程序启动时会自动隐藏命令行窗口（生产构建建议同时加 `-H windowsgui` 编译标志彻底消除黑色窗口闪烁）。使用 `-nogui` 参数可跳过托盘，纯命令行运行（适合服务器、SSH 远程场景）。

#### Windows 系统服务模式（支持登录界面控制）

> **场景**：电脑启动后尚未登录，想用手机远程输入开机密码；或锁屏后需要远程解锁。

普通用户进程受 Windows 安全桌面隔离，无法向登录界面（Winlogon 桌面）注入输入。系统服务模式通过以下架构解决：

```text
正常运行的 exe（Session 1，用户）
  └─ 托盘 → "安装为系统服务" → UAC 提示 → 写入 SCM
                                                ↓
开机自动：SCM 启动 exe -service（Session 0，SYSTEM）
  └─ 获取 winlogon.exe 的 SYSTEM 令牌
  └─ CreateProcessAsUser → exe -worker（Session 1，SYSTEM）
        ├─ 监听 UDP 8888（直接处理所有控制指令）
        └─ OpenInputDesktop → SetThreadDesktop → SendInput
             ├─ 登录界面时：注入到 Winlogon 桌面（可输入密码）
             └─ 正常桌面时：注入到 Default 桌面（常规控制）
```

**安装步骤**：

1. 以**普通模式**运行 `lan-remote-server.exe`（不需要管理员）
2. 托盘图标右键 → **"安装为系统服务"** → 弹出 UAC 提示，确认后自动安装并启动
3. 重启系统，无需登录即可用手机 App 连接并控制鼠标键盘、输入密码

**卸载**：托盘图标右键 → **"卸载系统服务"** → 确认 UAC

> 服务安装后，"开机自启动"注册表项可选择性移除（服务本身已实现开机自启）。网页配置页（`/api/service/status`）也可查看和管理服务状态。

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

# 自定义快捷键（共10个槽位，名称不为空则在 App 中显示）
# 格式：command+shift+a（不区分大小写；command 在 Windows 上自动替换为 ctrl）
custom_1_name=
custom_1_desc=
custom_1_keys=
# ... 以此类推至 custom_10_name / custom_10_desc / custom_10_keys
```

自定义快捷键也可以通过**网页配置界面**直接编辑，无需手动修改配置文件。

---

### 主控端（iPhone）

**依赖**：Flutter 3.22+，Xcode 15+，真机运行需要 Apple 开发者账号

```bash
cd client
flutter pub get
flutter run --release   # 连接 iPhone 后运行
```

启动后进入**设备列表页**：

- 历史成功连接的设备以**头像卡片**形式展示，卡片中央显示系统图标（Windows 旗帜 / Apple 标志 / Linux 企鹅），卡片下方显示设备名称（首次连接后显示系统主机名，否则显示 IP）
- **点击卡片**：触发连接动画，成功后进入控制界面，并将服务端返回的主机名、OS 类型、MAC 地址更新到本地历史记录
- **长按卡片**：弹出确认框删除该历史记录
- **新增地址**（底部按钮）：填写 IP、端口（默认 8888）、密码后连接；若无任何历史记录则直接显示此表单

> 连接成功后凭据自动保存，下次启动 App 显示在卡片列表中并自动尝试连接最近一次的设备。手动点击断开则不触发自动重连。

连接成功后进入**控制界面**，AppBar 显示：

- 服务端 OS 图标（SVG）+ **主机名**（或 IP）
- **延迟徽章**：实时网络延迟，绿色 ≤50ms / 黄色 ≤150ms / 红色 >150ms
- **心跳指示**：⬆️ 表示 Ping 已发出，✅ 表示 Pong 已收到；进入控制界面后屏幕保持常亮（Wakelock），退出后恢复系统默认

---

## 功能详解

### 触摸板

| 手势 | 动作 |
| -- | -- |
| 单指滑动 | 鼠标指针移动 |
| 单指轻敲 | 左键单击 |
| 单指快速双敲（< 300ms） | 左键双击 |
| 单指长按（> 300ms）后滑动 | 按住左键拖拽，松开释放 |
| 双指轻敲 | 右键单击 |
| 右侧弹簧滑块上下拖动 | 鼠标滚轮（松手后弹回中位） |

顶部快捷按钮：左键 / 右键 / 中键 / 双击

底部大按钮：左键（支持长按拖拽）/ 右键

**设置面板**（触摸板与飞鼠合并为一张折叠卡，默认折叠，点击顶部「设置」展开）：

- 触控灵敏度：0.5 ~ 5.0，控制指针移动速度
- 滚轮灵敏度：0.3 ~ 4.0，控制每 30 像素滑动触发的滚轮次数
- 飞鼠灵敏度：1 ~ 20，默认 8
- 启动 / 停止飞鼠按钮

所有灵敏度自动持久化，下次启动恢复。

---

### 空中飞鼠

竖持 iPhone，通过陀螺仪姿态控制鼠标：

| 动作 | 效果 |
| -- | -- |
| 左右转动手机 | 鼠标横向移动（偏航轴） |
| 前后倾斜手机 | 鼠标纵向移动（俯仰轴） |

**算法**：纯陀螺仪积分（Z 轴→横向，X 轴→纵向），响应即时、无回弹。磁力计数据仅用于诊断信息展示，不参与鼠标位移计算。

- **底部**左键 / 右键大按钮，均支持**长按**（按住期间被控端鼠标持续按下，松开后释放，可配合飞鼠做拖拽操作）
- 发送频率节流至 60 Hz，避免网络拥塞

---

### 键盘

#### 快捷键面板

| 区域 | 包含按键 |
| -- | -------- |
| 控制键 | Esc、Tab、退格、Delete、Home、End、Page Up/Down |
| 方向键 | ↑ ↓ ← → |
| 功能键 | F1 ~ F12 |
| 媒体键 | 播放/暂停、上一首、下一首 |
| 音量控制 | 滑块（左右拖动，每格 = 1 次音量键），静音按钮 |

**编辑快捷键**（OS 自适应，macOS 用 Cmd，Windows 用 Ctrl）：

| 操作 | macOS | Windows |
| -- | ----- | ------- |
| 全选 | Cmd+A | Ctrl+A |
| 复制 | Cmd+C | Ctrl+C |
| 剪切 | Cmd+X | Ctrl+X |
| 撤销 | Cmd+Z | Ctrl+Z |
| 重做 | Cmd+Shift+Z | Ctrl+Y |
| 保存 | Cmd+S | Ctrl+S |

**系统操作**（底部区域，OS 自适应）：

| 操作 | macOS | Windows |
| -- | ----- | ------- |
| 切换应用 | Cmd+Tab | Alt+Tab |
| 任务视图 | Ctrl+↑（Mission Control） | Win+Tab |
| 显示桌面 | Ctrl+F3 | Win+D |
| 截图 | Cmd+Shift+3 | PrintScreen |
| 锁屏 | Ctrl+Cmd+Q | Win+L |
| 睡眠 | pmset sleepnow | 系统休眠 |
| 关机 | AppleScript shut down | shutdown /s（需确认） |
| 重启 | AppleScript restart | shutdown /r（需确认） |

关机 / 重启操作会弹出确认对话框，防止误触。

**自定义快捷键**：

在服务端网页配置中定义最多 10 个自定义快捷键（名称 + 可选说明 + 快捷键字符串）。App 登录后自动拉取，有效条目（名称非空）显示在键盘页的独立卡片区域，点击即触发。

- 快捷键格式：`command+shift+a`（`+` 分隔，大小写不限）
- 修饰键自动适配当前 OS：`command` 在 macOS 保持不变，在 Windows / Linux 自动替换为 `ctrl`；`win/super` 在 Windows 映射为 `lwin`
- 支持 emoji 名称，如 `📺 全屏`、`🎵 播放`
- **说明（desc）始终显示在按钮名称下方**，无需长按即可看到备注

#### 文本发送面板

在文本框输入内容后发送，支持两种输入模式（模式自动持久化）：

| 模式 | 原理 | 适用场景 |
| -- | -- | -------- |
| 剪贴板粘贴（默认） | 服务端写剪贴板 → 触发 Cmd/Ctrl+V | 速度快，支持中文、emoji、长文本 |
| 逐字输入 | 服务端调用 TypeStr 逐字符发送 | 不支持粘贴的输入框（如远程桌面、游戏） |

**逐字模式**下，输入框每输入一个字符即立即发送、无需按按钮；退格键在空输入框也能被检测（零宽空格哨兵）。

---

### 操作宏

底部导航第三个 Tab，支持在 App 内创建、编辑和执行宏脚本，宏保存在 App 本地。

#### 宏列表

每条宏仅显示名称，右侧三个操作按钮：

| 按钮 | 说明 |
| -- | ---- |
| ▶ 执行 | 逐条向被控端发送指令；执行期间底部显示进度条和「停止」按钮 |
| ✏ 编辑 | 进入宏编辑器 |
| 🗑 删除 | 弹出确认框后删除 |

右下角操作按钮区域：**导入**（从手机剪贴板读取 base64 数据）、**导出**（将所有宏编码为 base64 并写入手机剪贴板）、**+** 新建宏。导入时可选择「覆盖」或「追加」已有宏。

#### 宏编辑器

- **顶部**：宏名称输入框（留空则按时间戳自动命名）+ 右上角「保存」按钮
- **中间**：多行文本编辑器，每行一条指令
- **底部**：横向滚动快捷输入芯片（点击即在光标处插入对应指令）

#### 指令语法

| 格式 | 含义 | 示例 |
| -- | -- | ---- |
| `command+shift+a` | 按键组合，`+` 分隔修饰键与目标键 | `command+c`、`ctrl+alt+del` |
| `sleep+N` | 延迟 N 秒（由手机端等待，不发包） | `sleep+1`、`sleep+0.5` |
| `w+文字` | 逐字输入文本 | `w+hello world`、`w+密码123` |
| `# 注释` | 以 `#` 开头的行被忽略 | `# 打开终端` |

修饰键自动适配 OS：`command` 在 macOS 保持不变，在 Windows / Linux 自动替换为 `ctrl`。

---

### 粘贴板监视

底部导航第四个 Tab，实时同步被控端剪贴板，方便在手机上查看、管理并回传文本。

#### 工作原理

服务端每 **500ms** 轮询一次系统剪贴板（`robotgo.ReadAll()`），若内容有变化，则将明文以 Base64 编码后通过 UDP `0x12` 主动推送给所有 30 秒内活跃的客户端；App 收到后解码并追加到本地历史列表。

#### 历史列表

- 收藏项置顶，非收藏项最多保留 **20 条**，超出时自动删除最旧的
- 收藏项底色略深、带蓝色边框，不受数量限制
- 同一内容再次收到时自动去重（移到顶部，收藏状态保留）
- 所有历史记录持久化保存在 App 本地（SharedPreferences）

#### 每条记录操作

| 操作 | 说明 |
| -- | ---- |
| 点击文字区域 | 直接发送文本到被控端（等同「发送」按钮） |
| 发送按钮 ▶ | 将文本通过 `0x05`（剪贴板模式）发送到被控端 |
| 复制按钮 📋 | 将文本复制到**手机**剪贴板 |
| 收藏按钮 ⭐ | 切换收藏状态 |
| 删除按钮 ✕ | 从历史列表中移除 |

#### 底部操作栏

| 按钮 | 说明 |
| -- | ---- |
| 导入 | 从手机剪贴板读取 Base64 数据，解析后追加或覆盖历史记录 |
| 导出 | 将全部历史记录编码为 Base64 并写入手机剪贴板 |
| 清空全部 | 删除所有非收藏记录（弹出确认框，收藏项保留） |

---

## 连接与心跳

1. **时间同步握手**：连接时客户端发送 `[0x00][密码长度][密码]`，服务端回复当前时间戳 + OS 标识 + 认证结果；**认证成功时**额外附加主机名和所有网卡 MAC 地址，客户端保存后显示为设备卡片名称；客户端用 RTT / 2 补偿时钟偏差
2. **自定义快捷键同步**：握手成功后客户端立即发送 `[0x11]` 请求快捷键列表，服务端返回 JSON 数组，App 渲染到键盘页
3. **双向心跳**：连接后每 3 秒客户端发 Ping（`0x10` + 时间戳 8B），服务端回 Pong 并携带原始时间戳（客户端可计算 RTT）；若 4 秒内未收到 Pong，则静默重连（重新握手）最多 3 次；3 次均失败后弹回连接页
4. **陈旧包丢弃**：服务端检查每个控制包时间戳，超过阈值（默认 50ms）的包直接丢弃，防止网络抖动堆积指令

---

## UDP 协议

大端序，通用格式：`[Cmd 1B] + [Timestamp 8B] + [Payload N B]`

| 指令 | Cmd | Payload 格式 | 说明 |
| -- | --- | ------------ | ---- |
| 时间同步 | `0x00` | `[pwd_len 1B][password N B]` | 握手，服务端回 `[0x00][time 8B][os 1B][auth 1B]`；认证成功时额外追加 `[hn_len 2B][hostname][mac_count 1B][mac1 6B]...` |
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
| 按键组合 | `0x0C` | `len(UInt16) + UTF-8` | 如 `command+shift+a`；修饰键自动适配当前 OS |
| 心跳 Ping | `0x10` | `[timestamp 8B]`（可选） | 服务端回同样格式；旧格式仅 1 字节 |
| 获取快捷键 | `0x11` | 无（单字节，无时间戳） | 请求自定义快捷键列表；服务端回 `[0x11][len 2B][JSON]`，JSON 格式见下 |
| 粘贴板推送 | `0x12` | `len(UInt16) + Base64 UTF-8` | **服务端主动推送**，无时间戳前缀；Base64 解码后为剪贴板明文 |

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
| `0x20`–`0x29` | 自定义快捷键 1–10（在网页配置中定义） |

**0x11 响应 JSON 格式**（仅返回名称非空的条目）：

```json
[
  {"idx": 0, "name": "📺 全屏", "desc": "切换全屏", "keys": "command+f"},
  {"idx": 2, "name": "🎵 播放", "desc": "",          "keys": "space"}
]
```

`idx` 为 0-based 槽位编号，对应 sys action 码 `0x20 + idx`。

---

## 项目结构

```text
.
├── server/
│   ├── main.go                      # UDP 监听、指令分发、系统操作、worker 模式路由
│   ├── tray.go                      # 系统托盘（fyne.io/systray）
│   ├── webconfig.go                 # 本地 HTTP 配置服务 + 内嵌网页（含服务管理 API）
│   ├── service_windows.go           # Windows 服务安装/卸载/SCM 处理/Session 工作进程注入
│   ├── service_notwindows.go        # 非 Windows 平台桩
│   ├── desktop_input_windows.go     # Windows 直接 SendInput（支持 Winlogon 桌面切换）
│   ├── desktop_input_notwindows.go  # 非 Windows 平台桩
│   ├── autostart_darwin.go          # macOS LaunchAgent 自启动
│   ├── autostart_windows.go         # Windows 注册表自启动
│   ├── autostart_linux.go           # Linux systemd user service 自启动
│   ├── hidewindow_windows.go        # FreeConsole 隐藏黑窗口
│   ├── hidewindow_notwindows.go     # 非 Windows 平台桩
│   ├── assets/
│   │   └── app_icon.png             # 托盘图标（编译期嵌入）
│   ├── server.conf                  # 运行时配置（密码、端口、超时、日志、自定义快捷键）
│   ├── go.mod
│   └── go.sum
└── client/
    ├── pubspec.yaml
    └── lib/
        ├── main.dart                        # App 入口、主题
        ├── services/
        │   ├── udp_service.dart             # UDP 通信、时间同步、心跳、断开通知流、粘贴板推送流
        │   ├── macro_service.dart           # 宏列表本地持久化（SharedPreferences）
        │   └── clipboard_service.dart       # 粘贴板历史本地持久化（SharedPreferences）
        ├── screens/
        │   ├── connection_screen.dart       # 连接页（自动重连、凭据持久化、WoL 唤醒）
        │   ├── control_screen.dart          # Tab 框架（主机名、延迟徽章、心跳指示）
        │   ├── touchpad_screen.dart         # 触摸板 + 飞鼠（合并设置卡、弹簧滚轮）
        │   ├── keyboard_screen.dart         # 键盘（快捷键、逐字输入、系统操作）
        │   ├── macro_screen.dart            # 宏列表（执行、编辑、删除、导入导出）
        │   ├── macro_editor_screen.dart     # 宏编辑器（指令编辑 + 快捷输入芯片）
        │   └── clipboard_screen.dart        # 粘贴板监视（历史列表、发送、收藏、导入导出）
        ├── models/
        │   ├── macro.dart                   # 宏数据模型
        │   └── clipboard_item.dart          # 粘贴板条目数据模型
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
| `github.com/go-vgo/robotgo` | 跨平台鼠标键盘控制（普通模式） |
| `fyne.io/systray` | 跨平台系统托盘（轻量，无 GUI 框架依赖） |
| `golang.org/x/sys/windows/svc` | Windows Service Control Manager 集成 |
| `golang.org/x/sys/windows` | Windows API（SendInput、桌面切换、进程注入） |

### 主控端

| 包 | 用途 |
| -- | ---- |
| `sensors_plus` | 陀螺仪传感器（飞鼠模式） |
| `shared_preferences` | 本地持久化（设备历史、灵敏度、输入模式） |
| `flutter_svg` | 渲染 SVG 格式的系统图标（Windows / Apple / Linux） |
| `wakelock_plus` | 控制界面防止屏幕休眠 |

---

## 常见问题

**Q: macOS 上鼠标/键盘没有响应？**
A: 前往「系统设置 → 隐私与安全性 → 辅助功能」，添加并勾选 `lan-remote-server`。

**Q: 粘贴模式只打出了字母 v？**
A: 同上，辅助功能权限未授予时 `KeyDown("command")` 无效。授权后重新测试。

**Q: 连接超时 / 找不到设备？**
A: 确认手机和电脑在**同一 Wi-Fi** 下，且服务端正在运行。部分路由器开启了 AP 隔离，需在路由器设置中关闭。

**Q: 连接后 iPhone 会自动息屏断连吗？**
A: 不会。进入控制界面后 App 会自动禁止屏幕休眠（Wakelock），退出控制界面后恢复系统默认。

**Q: App 支持深色/浅色模式吗？**
A: 支持。App 跟随 iOS 系统设置自动切换深色 / 浅色模式，无需手动操作。

**Q: 陀螺仪飞鼠移动鼠标后会自动弹回去？**
A: 已修复。原因是磁力计互补滤波的修正力会产生回弹，现已改为纯陀螺仪积分，鼠标移动后不再弹回。磁力计数据仅用于诊断展示。

**Q: 陀螺仪飞鼠长期使用后偏航漂移？**
A: 纯陀螺仪积分模式下，长时间使用可能有轻微漂移。停止飞鼠后重新启动可重置偏移量。

**Q: 如何设置密码？**
A: 点击托盘图标 → 「设置...」，浏览器会打开本地配置页，修改密码后点「保存」即时生效。也可直接编辑 `server.conf` 中的 `password=` 字段后重启。

**Q: 想更改监听端口？**
A: 点击托盘图标 → 「设置...」，在网页中修改端口后保存，**立即生效**（无需重启，主控端重新连接即可）。主控端连接界面的「端口」字段同步修改。

**Q: 如何设置开机自启动？**
A: 点击托盘图标 → 「开机自启动」切换开关即可。macOS 通过 LaunchAgent 实现，Windows 写入注册表 `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`，Linux 生成 systemd user service。Windows 下也可安装为系统服务（见上文），服务本身即为自启动，无需再设置注册表项。

**Q: 想在电脑开机后、登录前就能用手机控制（输入密码）？**
A: Windows 下安装为系统服务即可。托盘图标右键 → 「安装为系统服务」，之后服务开机自动启动，并在登录界面（Winlogon 桌面）注入输入。macOS 的登录界面受 SIP 保护，暂不支持。

**Q: 系统服务模式下登录后普通控制还能用吗？**
A: 可以。Worker 进程通过 `OpenInputDesktop` 实时探测当前活跃桌面：登录界面时切换到 Winlogon 桌面，正常桌面时切换到 Default 桌面，两种场景无缝切换，不需要重新连接。

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
