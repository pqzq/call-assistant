# 话务助手（call_assistant）

[![APK 构建与发布](https://github.com/pqzq/call-assistant/actions/workflows/apk.yml/badge.svg)](https://github.com/pqzq/call-assistant/actions/workflows/apk.yml)

导入一份 Excel 名单 → 自动识别「手机号」列 → 点击号码跳转系统拨号页并自动填充号码。

## 功能

- 选择本机 `.xlsx` 文件（手机上是「文件」选择器，无需存储权限）
- 多工作表切换，导入时自动挑出最合适的工作表
- **电话号码列自动识别 + 多选**：
  - 表头关键词（手机 / 电话 / 联系方式 / 手机号码 / phone / mobile / tel …）优先，再结合单元格内容是否为号码格式打分
  - **可以同时勾选多列**（如「手机号码」+「办公电话」），首页用标签任意增删，卡片右上角显示「已选 N 列」
  - 识别不准时同样可手动勾选正确列
- 名单列表：一条记录可展示多个号码（按列名标注手机/固话），点击卡片弹出**号码选择器**挑一个拨打，点击某个号码则直接拨它
- **拨号时高亮当前行**：点号码跳到系统拨号器的那一刻，该行变成浅蓝底 + 主色描边 + 阴影，行首序号变实心蓝、标题旁显示「正在拨打」，**并一直保持**（不会自动消失），方便确认刚拨的是哪一条；再拨别的行则高亮转移
  - 重置时机：点标题栏的**刷新**按钮 / 菜单里的「刷新列表（清除高亮）」、返回首页后重新进入列表、切换工作表、重新导入表格
  - 刷新只清高亮，**不影响「已呼叫」绿色标记**（那是历史记录，持久保存）
- **座机自动补区号**：
  - 号码只写了本地座机（如 `88886666`、`51234567`）时，拨号会自动加上设置的区号，列表里也会标注「已补区号 021」
  - 默认区号 **021**，首页「固话区号」卡片可从 021 上海 / 010 北京 / 020 广州 / 0755 深圳 / 0571 杭州 / 025 南京 / 027 武汉 / 022 天津 / 023 重庆 / 028 成都 / 0451 哈尔滨 / 0531 济南 中快捷选择，也可手填自定义区号（3-4 位、以 0 开头），选择结果本地持久化
  - 已自带区号的号码（`010-88886666`、`02166668889`）、手机号、国际号码完全不受影响，不会重复补
- 支持的号码写法：`13800138000`、`138 0013 8000`、`138-0013-8000`、`+86 13800138000`、`010-88886666`、`88886666`（补区号）、科学计数法 `1.3800138E+10`、`13800138000 转 123`
- **双机联动播报（实验特性）**：拨号手机检测到对方接通后，通过局域网通知另一台手机朗读固定开场白，详见下文
- 搜索过滤（姓名 / 号码 / 其他字段）、复制全部号码（同一行多号码用「、」分隔，固话带区号）、已呼叫标记（本地持久化）
- 内置两张示例工作表：「客户名单」（手机号）和「固话名单」（座机，可直观看到补区号效果）

> 拨号使用系统 `tel:` Intent：号码会**自动填入拨号页**，仍需用户点一下拨打键，这样不需要 `CALL_PHONE` 权限。

## 目录结构

```
lib/
├─ main.dart                      应用入口、主题
├─ models/sheet_data.dart         ImportedSheet / PhoneCandidate / CellField
├─ services/
│  ├─ excel_service.dart          Excel 解析 + 表头/手机号列识别（含示例数据）
│  ├─ dialer_service.dart         调起系统拨号页
│  ├─ settings_store.dart         固话区号等本地设置
│  ├─ call_log_store.dart         已呼叫号码本地存储
│  ├─ call_state_watcher.dart     无障碍通话状态通道（EventChannel）
│  ├─ lan_link.dart               局域网 UDP 广播通道
│  ├─ live2d_service.dart         Live2D 资源释放 + 本地静态服务 + 模型导入
│  ├─ tts_synthesizer.dart        端侧 TTS 合成（sherpa-onnx）+ 振幅包络
│  └─ prompt_link.dart            双机联动编排（接通→广播→朗读→口型）
├─ utils/phone_utils.dart         号码归一化、类型识别（手机/固话/本地座机）、区号补全
├─ pages/
│  ├─ home_page.dart              导入、参数确认（工作表 / 手机号列 / 统计）
│  ├─ record_list_page.dart       名单列表、搜索、拨号
│  └─ prompt_page.dart            双机联动配置（角色 / 开场白 / 日志）
└─ widgets/
   ├─ record_card.dart           单条记录卡片
   └─ live2d_avatar.dart         Live2D 数字人组件（WebView + 嘴型驱动）
test/                               18 个用例（号码解析 / Excel 导入 / 列识别 / 界面冒烟）
android/                            gradle 工程 + 带 <queries> 的 AndroidManifest
```

## 本机环境与运行

| 组件 | 路径 / 版本 |
| --- | --- |
| Flutter SDK | `D:\Android\flutter\sdk\flutter`（3.47.7，未加入 PATH） |
| Android SDK | `D:\Android\android-sdk`（platform-tools 37.0.1、platforms;android-36、build-tools;36.0.0） |
| JDK | `D:\Java\temurin\jdk-17.0.19+10`（Temurin 17，JAVA_HOME 已设置） |

环境变量已写入用户级：`ANDROID_HOME`、`ANDROID_SDK_ROOT` 指向 SDK，PATH 追加了 `platform-tools` 和 `cmdline-tools\latest\bin`；`flutter config --android-sdk D:\Android\android-sdk` 已设置。`flutter doctor` 报 `[√] Android toolchain (SDK 36.0.0)`、许可全部接受。

```powershell
cd d:/test/flutter/call-assistant
flutter pub get
flutter test            # 18 个用例：号码解析、Excel 导入、手机号列识别、界面冒烟
flutter analyze
flutter run             # 连手机直接调试
flutter build apk --release
```

产物：

- `build\app\outputs\flutter-apk\app-release.apk`（48.9MB，已验证可安装：包名 `com.callassistant.call_assistant`，label「话务助手」，minSdk 24 / targetSdk 36，含 `tel:` 的 `<queries>`）
- `build\app\outputs\flutter-apk\app-debug.apk`（151.5MB）

> 本机网络对 `github.com` / `maven.google.com` 不通，因此 `android/gradle/wrapper/gradle-wrapper.properties` 的 `distributionUrl` 指向腾讯云镜像，`android/settings.gradle.kts` 与 `android/build.gradle.kts` 的仓库列表前置了腾讯云/华为云 Maven 镜像（官方源保留在后面兜底）。换到能直连的网络时可以把镜像删掉。
>
> `android/gradle.properties` 关闭了 Kotlin 增量编译（Windows 下偶发 `Could not close incremental caches`）。

## 双机联动播报（实验特性）

> 场景：真实手机号外呼时，让对方听到固定的开场白。Android 不允许第三方应用把音频注入蜂窝通话上行，所以这里用**两台手机 + 声学耦合**的方式实现：
> 拨号手机检测「已接通」→ 局域网通知播放手机 → 播放手机在拨号手机麦克风旁朗读。

```
手机A（拨号端）                      手机B（播放端，放在A的麦克风旁 5~10cm）
点击号码 → tel: 拨号
   │
   ├─ 无障碍服务读取通话界面
   │   出现 00:05 / 通话中 → 判定已接通
   │
   └─ UDP 广播 255.255.255.255:47823  ──▶  收到 answered 指令
        {type:answered, script:"开场白"}      → flutter_tts 朗读开场白
```

### 接通判定（无障碍）

系统没有给第三方开放「外呼已接通」回调（`CALL_STATE_OFFHOOK` 在拨号时就触发了），
所以只能读通话界面文案来判断。**判据优先级**（`CallAnswerAccessibilityService`）：

| 顺序 | 条件 | 结论 |
| --- | --- | --- |
| 1 | 出现「通话结束 / 已挂断」 | 通话结束 |
| 2 | 出现「**正在拨号 / 正在呼叫 / 呼叫中 / 已拨出**」 | **未接通**（忽略后续） |
| 3 | 出现「通话中 / 已接通 / 正在通话 / 通话时长」 | 已接通 |
| 4 | 计时器**数值在变化**（两次采样不同） | 已接通 |

两个关键坑：

- **拨号界面里也有时间**（MIUI 拨号盘顶部是时钟，状态栏也是 `21:30`），
  只靠「出现 `数字:数字`」会把**刚拨出去还没接通**就判成接通。
  → 现在要求计时器**确实在走动**（两次采样值不同）才算通话计时器。
- **呼叫中界面已经有红色挂断键**（和通话中界面一样），
  → 所以「挂断」不能作为接通判据，只能作为辅助信息。

实测：拨出未接通的号码（呼叫中界面顶部显示「正在拨号」）**不再误报**；
接通后界面会出现「已接通」或开始走动的通话计时器 → 正常触发播报。

### 打断播报

联动页快捷条上「立即播报」旁边有 **「停止」**：

- 停掉本机正在播放的音频/TTS 与嘴型动画
- 同时通过局域网广播 `stop` 指令，让**播放端**也立刻停下（否则只停了拨号端，播放端还在念）
- 播放端收到 `stop` 后执行 `stopSpeaking()` 并记录「收到停止播报指令」
- 另外播放端收到新的播报指令时会**先停掉正在播的内容**再播新的，避免叠音

### 名单列表的紧凑模式

表格可能有几百行，所以名单页默认用**紧凑模式**：

```
① 张伟                        📞
  手机号码 13800138000  办公电话 010-88886666
  部门: 销售一部 · 备注: 首次咨询
```

- 每行压到约 60 高（详细模式约 120），**一屏能看到的行数多一倍以上**
- 序号变成小圆点，号码**横排**显示并可直接点击拨打，右侧一个圆形拨号按钮
- 第二行是字段摘要（部门/备注等，最多两条，自动跳过与序号重复的字段）
- 标题栏有「密度切换」按钮，可在**紧凑 / 详细**之间切换，选择会被记住
- 列表用 `ListView.builder` 懒加载，几百行也能流畅滚动

### 提示样式（居中浮层）

全局提示不再用底部 SnackBar，改为**居中浮层**（`lib/widgets/app_toast.dart`）：

- 居中显示，不遮挡底部操作区（悬浮玻璃按钮所在的位置）
- 主题色渐变（`#4A82FF → #2F6BFF`）+ 图标 + 白字；错误提示用红色系，一眼可辨
- 自动淡入淡出 + 轻微缩放，**不打断操作**（`IgnorePointer`，点击可以穿透）
- 生命周期用单个 `AnimationController` 走完「入场 → 停留 → 退场」，不用 Timer（否则 widget 测试的 `pumpAndSettle` 会一直等下去）

### 名单列表双列 + 拨号页布局

**名单列表页：双列多行**

```
┌────────────┐ ┌────────────┐
│ ① 中国移动客服 │ │ ② 中国联通客服 │
│   手机号码    │ │   手机号码    │   ← 窄卡里号码竖排（标签在上）
│   10086     │ │   10010     │
│   办公电话    │ │   办公电话    │
│   010-8888… │ │   010-8888… │
│   部门: 客服热线│ │   部门: 客服热线│
└────────────┘ └────────────┘
```

- 紧凑模式改成**两列网格**，左右留白收紧让每列更宽（号码不易换行），卡片高度只够「姓名 + 号码 + 拨打情况」（84），一屏能看 12+ 张卡
- 拨号图标已移除（省下的空间全给号码，双列 15px、单列 17px）
- 号码与列名**同一行**（手机号码 10086），长号码用 FittedBox 自动缩放，不换行不截断
- 已标记的拨打情况显示为绿色小标签
- **长按卡片**可弹出该行**完整信息**（弹窗整体下沉，从屏幕更下方升起）：所有号码（可直接点拨）+ 全部字段 + **拨打情况设置**（短按仍是拨号，单列/双列都支持）

**拨打情况（表格末尾新增一列）**

- 导入表格时**自动在末尾追加「拨打情况」列**；长按卡片的弹窗里可以一键标记：拨打成功 / 未接听 / 已关机 / **自定义填写**（弹输入框自己写，如「客户说下周一再联系」），也能清空
- 标记结果写回该行的「拨打情况」列，并在卡片上显示为绿色小标签
- 同时按「表格名 + 行号」存到本地，下次进同名表格会自动带回来
- **导出为 xlsx**：列表页右上角菜单 →「导出为 xlsx（含拨打情况）」，把表头 + 全部数据行（拨打情况在最后一列并已填充）写成 xlsx
  - 直接通过 **MediaStore 存到系统「下载」目录**（不需要任何存储权限，也不会被系统保存对话框卡住），提示里会给出文件路径
  - 极端情况下退回系统「另存为」对话框
- **清空所有拨打情况**：同一菜单里，二次确认后清空当前表格全部行（含本地缓存）
- 导出的文件再导入时**不会**重复追加「拨打情况」列（会复用已有同名列）
- 标题栏在**排版（密度）按钮左边**新增「双机联动播报」快捷跳转；切到详细模式仍是单列大卡片

**拨号页（首页）**

```
┌───────────────┬───────────────┐
│ 工作表          │ 统计          │  ← 两卡顶部对齐
├───────────────┴───────────────┤
│ 电话号码列（可多选）               │  ← 号码列在区号上面
├───────────────────────────────┤
│ 固话区号（chip 多列排开）           │
└───────────────────────────────┘
   ┌───────────────────────────┐
   │ [导入其他表格] │ [开始拨号] │  ← 悬浮液态玻璃条
   └───────────────────────────┘
```

- 「工作表」与「统计」两张卡**顶部对齐且等高**（IntrinsicHeight）；点左边卡片可弹出「表格信息」看完整文件名、数据行、列数、表头位置等（标题被截断时也能看全）
- 「电话号码列」放在「固话区号」**上面**
- 「导入其他表格」与「开始拨号」做成**悬浮液态玻璃条**（背景模糊 + 半透明渐变 + 高光描边 + 投影），始终可点、不随内容滚走

**表格导入成功率提升**

- 支持 **.xlsx / .xls / .csv / .txt**；csv、txt 直接按逗号或制表符分隔解析（支持双引号包裹与转义）
- 解析失败时会把底层原因带出来（不再只给一句「无法解析」），并提示如何另存为 xlsx
- 名单卡片的字段区**不展示「序号」项**（长按详情里仍能看到完整字段，含序号）
- 号码识别新增**服务号**类型：5~6 位的公开服务电话（`10086` / `10010` / `10000` / `12345`）。服务号与「编号 10001」太像，所以**单独判断**：只有当该列**表头命中电话关键词**、且列里还有标准格式号码时，才把服务号计入 —— 否则编号列会被误当成号码列

**内置示例名单**

前 3 行是三大运营商的客服热线（`10086` / `10010` / `10000`）——都是**公开服务电话**，接通后是语音提示，既能跑通「接通 → 播报」全链路，也不会打扰到真人。

### 数字人模型导入

- **按文件后缀识别模型**：`*.model3.json`（大小写不敏感，`Hiyori.model3.json` 与 `model3.json` 都认）；后缀被改过时再按**内容**兜底（json 含 `FileReferences` + `Moc` 即认为是模型描述文件）
- 「导入模型包（zip）」：选 zip 压缩包，自动找到里面的**模型描述文件**并连同贴图/动作/表情一起释放
- 「**从文件夹导入模型**」：直接选一个文件夹，递归查找模型描述文件，把模型所在目录整体复制到应用目录（适合已经解压好的模型）
  - 扫描会跟随符号链接、最多 8 层，并有一次性递归遍历兜底
  - 失败时给出**具体原因**（目录读不到 / 有 json 但不是模型描述文件 / 确实没有），不再一律报「没有找到 .model3.json」
  - **Android 11+ 分区存储**：需要「所有文件访问权限」（MANAGE_EXTERNAL_STORAGE）。没授权时点击「导入文件夹」会直接跳转到系统授权页，开启后再导入即可
  - 目录选择走**系统 SAF**（ACTION_OPEN_DOCUMENT_TREE）并在原生侧把 documentId 解析成真实路径（MIUI/HyperOS 的 
oot: 卷名也做了兼容），不依赖各 ROM 行为不一致的文件选择器
  - 找不到模型时会说明原因（目录读不到 / 有 json 但不是模型描述文件 / 确实没有）

### Windows 数字人的透明背景

Windows 的 WebView2 默认是**白色不透明**背景，会导致：

- 模型周围出现一圈白/灰块
- 浮窗贴到屏幕左/右边缘时，超出部分露出灰白条

处理方式（`live2d_avatar.dart` 的 `_bootstrapWindows`）：

```dart
await controller.setBackgroundColor(const Color(0x00000000));
```

- 只能传 **alpha = 0 的全透明**，传半透明会被 WebView2 当成不透明
- 页面本身也必须是透明背景（`assets/live2d/index.html` 里 `html, body { background: transparent; }`）
- Android 侧本来就通过 `webview_flutter` 设了同样的透明背景，两端表现一致
### 数字人模型的移除

「切换模型」列表里：

- **内置模型**（Haru / Hiyori / Mao / Mark / Natori / Rice / Wanko）**不可移除** —— 没有删除按钮
- **用户自己导入的模型**（路径以 `models/` 开头的）**可以移除**：点右侧的 🗑️ → 二次确认 → 连目录一起删除
- 移除的如果是**当前正在使用**的模型，会自动切回默认模型（Hiyori）

区分依据：内置模型放在资源根目录（`hiyori/`、`haru/` …），用户导入的统一放在 `models/` 下。

### 弹窗与确认框

- **长按详情弹窗**（名单页）：高度**随内容自适应**，内容少时弹窗就矮，不再在上方留大片空白；字段改成**双列**排布（标签 54px + 值），并去掉了与高亮 chip 重复的「当前拨打情况」行
- **确认弹窗统一**用 `lib/widgets/confirm_dialog.dart`：
  - 取消与确认按钮**固定在同一行**、宽度一致（`Row` + `Expanded`），不会被长文案挤成两行
  - 确认按钮**实心主题色**，危险操作（清空 / 移除模型）用**红色**，一眼能找到
  - 取消按钮为描边样式，不抢主操作的视觉权重
  - 标题可带图标（清空=扫帚、移除=垃圾桶）

### 开场白音频转文本（离线语音识别）

「播报」标签页 → **开场白音频**卡片 →「把这段音频转成文本」→ 识别结果弹窗（可直接改）→「填入」回写到开场白文本框。

**完全离线**：用 sherpa-onnx 的离线识别器（和端侧合成同一套技术栈），录音不会上传。

**支持全格式**：新增 Android 原生解码器（`AudioDecoder.kt`，MediaExtractor + MediaCodec），
mp3 / m4a / aac / ogg / wav / amr 等常见格式都能读，统一转成 16kHz 单声道 WAV 再送识别器。
解码结果写成文件而不是走 MethodChannel，避免长录音超 Binder 事务 1MB 限制。

**模型**（在「语音识别模型」卡片导入，`.tar.bz2` 格式，导入后自动识别，无需手动解压）：

| 模型 | 体积 | 说明 |
| --- | --- | --- |
| `sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17.tar.bz2` | 155 MB | 推荐，中文效果最好、自带标点 |
| `sherpa-onnx-paraformer-zh-small-2024-03-09.tar.bz2` | 74 MB | 更轻，速度快 |

- 模型目录：`/storage/emulated/0/Android/data/<包名>/files/sherpa-asr/`，也可直接用 adb 推入
- 识别开了**逆文本正规化**：数字会输出成「10086」而不是「一万零八十六」
- 开了标点，输出自带逗号句号

### PC 端（Windows / macOS / Linux）

PC 端定位为**播放端**：替代第二台手机，接收手机拨号端发来的播报指令并朗读（可带 Live2D 数字人）。

**平台差异（由 `lib/services/platform_bridge.dart` 统一收拢）**

| 能力 | Android | 桌面端 |
| --- | --- | --- |
| 拨号跳转（系统拨号页） | ✅ | ❌ 改为**复制号码** |
| 「拨号端」角色（检测接通） | ✅ | ❌ **隐藏**，PC 只当播放端 |
| 无障碍通话检测 | ✅ | ❌ 不支持 |
| 局域网双机联动 | ✅ | ✅ PC 与手机同 Wi-Fi 即可 |
| 立即播报 | 广播给播放端 | **本机播报** |
| Live2D 数字人 | ✅ | ✅（WebView2） |
| 端侧 TTS / ASR | ✅ | ✅（ASR 的音频解码暂仅 Android） |
| 保存导出文件 | 系统「下载」目录 | 系统保存对话框 |

**宽屏适配**：桌面端**内容区**限宽 820px 居中（`DesktopBody`），但 **AppBar 仍然通栏**，更像桌面应用；两侧用页面背景色铺满，不会露出黑块。

**桌面端的三个坑（都已处理）**

| 坑 | 现象 | 处理 |
| --- | --- | --- |
| `flutter_tts` 在 Windows 上调 SAPI | 机器没装语音引擎时**原生层崩溃**（整个 App 闪退，try/catch 拦不住） | 桌面端**完全禁用**系统 TTS，统一走端侧合成（导入 TTS 模型即可） |
| 缺 `webview_flutter_windows` | 数字人一片空白，报 `WebViewPlatform.instance != null` | pubspec 显式声明 `webview_flutter_windows`，并确认它出现在 `windows/flutter/generated_plugins.cmake` 里 |
| `webview_flutter_windows` 1.x **不是** `webview_flutter` 的平台实现 | 它是**独立的 WebView2 组件**（`Webview` / `WebviewController`），`WebViewController` 那套 API 在 Windows 上完全不可用 | 数字人组件按平台分两套实现：Android 用 `webview_flutter`，Windows 用 `webview_flutter_windows` 的 `loadUrl` / `executeScript` / `loadingState` |
| 缺 WebView2 Runtime | 数字人不加载（浏览器进程起不来，**不会**触发任何错误回调，只会一直白屏） | 安装 [WebView2 Runtime](https://developer.microsoft.com/microsoft-edge/webview2/)；App 内也有「下载 WebView2 Runtime」按钮 |


**构建 Windows**

```bash
# 一次性准备：开启「开发者模式」（Flutter Windows 插件需要创建符号链接）
#   设置 → 系统 → 开发者选项 → 开发人员模式
#   或用管理员 PowerShell：
reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock" /t REG_DWORD /f /v AllowDevelopmentWithoutDevLicense /d 1

flutter pub get
flutter build windows --release        # 产物在 build/windows/x64/runner/Release/
```

> 没有管理员权限时无法创建符号链接，构建会提示
> `Building with plugins requires symlink support`。

**构建 Windows**（两个一次性前置条件）

1. **开启「开发者模式」**（Flutter 插件构建需要创建符号链接）
   - 设置 → 系统 → 开发者选项 → 开发人员模式
   - 或用**管理员** PowerShell 执行：
     ```
     reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock" /t REG_DWORD /f /v AllowDevelopmentWithoutDevLicense /d 1
     ```
2. **安装 nuget.exe 并放进 PATH**（`flutter_tts` 的 Windows 实现要用它拉取 Speech API）
   ```
   curl.exe -L -o d:\tools\nuget.exe https://dist.nuget.org/win-x86-commandline/latest/nuget.exe
   $env:PATH="d:\tools;$env:PATH"     # 每次构建前确保它在 PATH 里
   ```

然后：

```
flutter pub get
flutter build windows --release        # 产物在 build/windows/x64/runner/Release/
```

> 若报 `file cannot create directory: C:/Program Files/...`，说明上次构建把安装前缀缓存成了 Program Files，
> 删掉 `build/windows` 目录重新构建即可。
### 桌面端的分栏布局（Windows / macOS / Linux）

桌面端**不再用浮窗**展示数字人，改成**左右分栏**：

```
┌──────────────┬────────────────────────────────┐
│  数字人       │  主操作界面                      │
│  ┌────────┐  │  ┌──────────────────────────┐  │
│  │ Live2D │  │  │ 播放端 / 立即播报 / 停止   │  │
│  └────────┘  │  │                          │  │
│  提词气泡     │  │  本机角色 / 单机自测       │  │
│  上一步 下一步 │  │  名单 / 数字人 / 日志       │  │
└──────────────┴────────────────────────────────┘
```

**为什么改**：Windows 的 WebView2 是**原生控件**（hybrid composition），浮在 Flutter 内容之上时会出现一串问题 —— 透明背景要等控件创建后设置才生效、resize 后背景色会被重置、Flutter 的裁剪对原生控件无效导致贴边露灰条。改成固定分栏后，数字人就是普通布局的一部分，行为稳定。

- 左栏宽度固定为**窗口宽度的 2/5**（DesktopSplitView.panelRatio，限制在 260~640px）
- 中间是 Live2D 角色（白底卡片内渲染，**没有裁剪/透明问题**）
- 下面是提词气泡（客户信息 + 话术提词，最大高度为**窗口高度的 40%**）
- 再下面是「上一步 / 下一步」和**「切换模型」快捷入口**（与手机端共用 ModelPickerSheet）

- **手机端保持原来的浮窗**（可拖动、可贴边收起）

实现上把「数字人 + 提词气泡」抽成 `lib/widgets/avatar_stage.dart`（`AvatarStage` / `AvatarBubble`），手机浮窗和桌面分栏共用一份渲染逻辑。

**Windows 数字人的几个坑（都已处理）**

| 坑 | 现象 | 处理 |
| --- | --- | --- |
| `webview_flutter_windows` 1.x **不是** `webview_flutter` 的平台实现 | 它是**独立的 WebView2 组件**（`Webview` / `WebviewController`），`WebViewController` 那套 API 在 Windows 上完全不可用 | 数字人组件按平台分两套实现：Android 用 `webview_flutter`，Windows 用 `loadUrl` / `executeScript` / `loadingState` |
| `setBackgroundColor` 调用时机 | 原生侧有 `IsValid()` 检查，控件没建好时**静默失败** | 放到 `loadUrl` 之后调用，并在导航完成时兜底重设 |
| resize 后背景色被重置 | 展开→贴边后背景又变回默认灰色 | 用 `LayoutBuilder` 感知宽度变化，变了就重设一次透明 |
| `dispose` 没释放原生控件 | 关掉数字人后还残留一块**擦不掉的灰色矩形** | `dispose` 里显式 `controller.dispose()` |
| 背景色只能全透明 | 插件把任何 alpha>0 的值都当成不透明 | 传 `Color(0x00000000)`，页面侧 `html, body { background: transparent }` |
### 开场白音频：固定一个文件

开场白音频**始终是同一个文件**（应用项目目录 `documents/opening_audio.wav`）：

- **端侧合成**（sherpa-onnx）直接写到这个文件，每次生成**覆盖**上一次的
- **导入外部音频**（mp3 / wav / m4a / aac / ogg）时复制过去，同样是覆盖
- 清除时连同 `.env.json`（嘴型包络）一起删掉
- 旧版本留下的 `opening_tts_<时间戳>.wav` 会在下次合成时自动清理，路径也会在启动时迁移到固定文件

好处：不会越攒越多临时文件，偏好设置里存的路径永远是同一个，也方便用户自己从应用目录取走。

### Windows 字体发虚的修复

Windows 的 Flutter 默认用 **Impeller** 渲染器，在部分显卡驱动上**文字（尤其中文）渲染发虚**。

修复方式是在引擎层直接关掉 Impeller（`windows/runner/main.cpp`）：

```cpp
flutter::DartProject project(L"data");
// Impeller 在部分 Windows 显卡驱动上文字渲染发虚，改用 Skia
project.set_impeller_switch(flutter::ImpellerSwitch::Disabled);
```

- 写进代码里，**不需要每次构建都加 `--no-enable-impeller`**（release 构建 tool 也不支持这个参数）
- Android / iOS 不受影响（Impeller 在移动端表现良好）
- 代价：Skia 在部分场景下性能略低于 Impeller，桌面端够用

### Windows 上本地服务起不来的坑

`path_provider` 在 Windows 上**不支持** `getExternalStorageDirectory()`（抛 `UnimplementedError`），`getApplicationDocumentsDirectory()` 同样不支持 —— 只有 `getApplicationSupportDirectory()` 能用。原来的写法是 `external ?? documents`，因为异常在 `??` 之前就抛出，两个都不支持时整个函数静默失败，表现为**数字人打不开、「切换模型」点了没反应**。

修法：`getExternalStorageDirectory()` 失败时回退到 `getApplicationSupportDirectory()`（`%APPDATA%\<company>\<app>\live2d`），并补了日志。


### 原生渲染（`flutter_live2d`）的两个上游 bug 与修复

原生后端依赖 `flutter_live2d` 1.0.2。这个插件开箱即用时**模型能加载但画面永远空白**，排查后确认是两个上游 bug（都已通过 `tool/patch_live2d_plugin.dart` 本地修补）：

#### Bug 1：CubismFramework 在没有 GL context 的线程初始化

```cpp
// 插件原始代码
nativeCreateView(JNIEnv*, jclass) {
    FrameworkRetain();          // ← 在 Android 主线程调用，无 EGL context
    Live2DView* view = new Live2DView();
    return ...;
}
```

`CubismFramework::Initialize()` 内部会 `CreateRenderer` → 生成 OpenGL **shader program**。没有 current context 时 shader 全部编译失败，program 恒为 `0`，之后每帧 `glUniform*` / `glDrawElements` 都报 `GL_INVALID_OPERATION (0x502)`。

**修复**：把初始化延迟到 `nativeOnSurfaceCreated()` —— 它在 render hub 线程执行，已 `eglMakeCurrent`，是唯一安全的时机。同时在 `Live2DView` 上加 `frameworkRetained` 标志，保证 `FrameworkRetain/FrameworkRelease` 配对。

#### Bug 2：shader 源文件没被打进 APK

Cubism 通过下面的方式读 shader：

```cpp
Live2DPal::LoadFileAsBytes("FrameworkShaders/VertShaderSrc.vert")   // → AAssetManager_open
```

也就是从 **APK assets** 里找 `FrameworkShaders/`。但插件的 `build.gradle.kts` 只配了 `java.srcDirs`，shader 文件一直躺在 `cpp/CubismFramework/Rendering/OpenGL/Shaders/StandardES/` 里，**从未进入 assets** → shader 加载返回 null → program 同样为 0。

**修复**：把 `StandardES/*.vert` / `*.frag`（36 个）复制到 `android/src/main/assets/FrameworkShaders/`。

#### Bug 3：模型适配用 SetWidth 导致瘦高模型被裁成半身

```cpp
// 插件原始代码
if (view->width > view->height)
    model->GetModelMatrix()->SetHeight(2.0f);   // 横容器：高度填满 ✓
else
    model->GetModelMatrix()->SetWidth(2.0f);    // 竖容器：宽度填满 → 高度溢出 ✗
```

竖容器里按**宽度**填满时，瘦高模型（如 Natori，宽高比约 0.49）的高度会达到视口高度的 1.4 倍以上 —— **头和脚都被裁掉，只剩半身**。

**修复**：统一改成「按高度填满」：

```cpp
const float aspect = (float)view->height / (float)view->width;
const float targetH = 2.0f * (aspect > 1.0f ? aspect : 1.0f);
model->GetModelMatrix()->SetHeight(targetH);
```

实测：`fit view=795x1104 aspect=1.389 targetH=2.777` → 模型完整显示且高度最大化。
#### 排查过程中确认过的「正常」项（避免误判）

| 检查项 | 结果 |
| --- | --- |
| 模型加载 | `LoadAssets done, IsLoaded=1` ✓ |
| 纹理上传 | `tex[0] id=1 1024x1024 texture_00.png` ✓ |
| MVP 矩阵 | `mvp=[1.57 0 0 0 \| 0 0 0 1]` ✓ |
| 渲染循环 | 每帧 `nativeOnDrawFrame` + `eglSwapBuffers` ✓ |
| 投影/视口 | `viewSize=1155x907`，比例正确 ✓ |

**唯一异常就是 `glErr`**：修好后从 `0x501 → 0x502` 变成恒为 `0x0`，模型立即正常显示。

#### 补丁怎么用

```bash
flutter pub get
dart run tool/patch_live2d_plugin.dart   # 幂等，重复执行安全
flutter build apk --release
```

- 脚本从 `.dart_tool/package_config.json` 定位插件目录，找不到就回退扫 pub cache
- 每一步都有幂等标记，已打过补丁会输出「已打过补丁」并跳过
- **每次 `flutter pub get` 重建 pub cache 后需要重新执行一次**
- CI 的 `ci` / `release-android` 两个 job 已在 `pub get` 之后自动执行


### 桌面端分栏里的弹窗 / Toast

`MaterialApp.builder` 返回的内容位于 **Navigator 之外**，所以桌面分栏里的控件：

- `showModalBottomSheet` 会抛「找不到 Navigator」→ **点了没反应**
- `Overlay.maybeOf(context)` 返回 null → **Toast 静默不显示**

修法：新增 `lib/services/app_navigator.dart`，用 `GlobalKey<NavigatorState>` 拿到全局 Navigator，弹窗和 Toast 都改走 `resolveNavigator(context)` / `resolveOverlay(context)`（优先用 context 上的，回退到全局 key）。


### 手机端悬浮数字人的排版

浮窗由「角色盒 + 右侧操作栏 + 下方话术框」组成，尺寸全部由 `FloatingAvatarHost` 的静态方法推导：

| 参数 | 值 | 说明 |
| --- | --- | --- |
| `avatarHeight(screenWidth)` | `screenWidth * 0.58`（clamp 260~420） | **角色盒高度先定**，竖屏下约 401 |
| `avatarAspect` | `0.60` | 角色盒宽 / 高（从 0.72 收窄，减少右侧空白） |
| `avatarBoxWidth` | `avatarHeight * 0.60` | 约 241 |
| `groupWidth` | `avatarBoxWidth + 84 + 8` | 约 333（整组宽度） |
| `barWidth` | `ArcActionBar.barWidth` = 84 | **左侧**弧形操作栏 |
| 图标 / 点击区 | `27` / `46` | 图标加大，方便点 |
| `barGap` | `8` | 角色盒与操作栏间距 |
| 话术框间距 | `6` | 与角色盒之间 |

**操作栏与拖动**

- 操作栏在角色**左侧**，图标沿**凹向**角色的弧线排布（月亮型，中间离角色最远、两端迎向角色轮廓），**无背景**，只有深色图标 + 白色外发光描边（浅/深背景都能看清）
- **关闭按钮是红色**（`ArcAction.danger`），拖动柄拖动时变主题蓝
- 话术框与**角色同宽**、左边缘对齐（不再横跨整组宽度）
- **角色本体也能拖动**（`GestureDetector` + `HitTestBehavior.translucent`，点击仍穿过到下层）
- 拖动时拖动柄变成主题蓝；**不要用 `Transform`/`AnimatedScale` 做拖动反馈** —— Android 平台视图（WebView/TextureView）不支持任意变换，一旦被 transform 包裹就整块不渲染（表现为模型消失）
- 话术只有一步时，**不显示上一步/下一步**（`scriptSteps.length > 1` 才加）

**话术框**：手机端用 `GlassSurface`（液态玻璃，**blur 32 + 白色 0.42**），文字依然清晰；桌面分栏仍用实心白底。`GlassSurface` 全局默认透明度也从 0.78 降到 0.60、描边从 0.85 降到 0.62，整体玻璃感更透。

**模型大小可调（`模型大小` 滑杆）**

Live2D 的 canvas 四周留白**各模型差异极大**（有的角色只占 canvas 中间 40% 宽），任何固定值都会出现「这个模型显得太小、那个被裁头脚」。所以：

- WebView 加载后用 `model.getLocalBounds()` 把比例报给 `PromptLink.avatarModelAspect`（持久化，换模型自动作废）
- 浮窗宽度 = `角色高度 × 模型比例`（clamp 0.28~0.90，且有 232 的**最小宽度**保证话术可读）
- 再加一个用户可调的 **`模型大小` 滑杆**（0.8~1.8x，默认 1.25），拖动时通过 `avatar.setZoom()` **实时重排，不重新加载页面**
- 原生后端复用同一个 zoom 值（`SetHeight(2.0 * aspect * zoom)`），在补丁脚本里

排查时踩的坑：`index.html` 改动后必须**升 `Live2dService.assetVersion`**，否则设备上的旧资源不会被重新释放（改了代码却看不到效果）。
**模型适配的「放大系数」**：Live2D 的 canvas 通常比角色本体大一圈，纯 `Math.min` 适配会让角色显得很小、两侧空一大片。WebView（`index.html`）与原生（`live2d_flutter.cpp`）都加了 `FIT_OVERSCAN = 1.12`，允许高度方向多溢出 12%，角色明显更饱满（溢出部分多在角色上方的空白）。

**为什么改成「以高度定宽度」**：Live2D 人物模型本身是**竖长**的（宽高比约 0.5~0.7）。早期把角色盒做成横向（420×330），模型按高度适配后**宽度只用了一半**，两侧全是空白 —— 就是「数字人比框小很多、看着松散」的原因。改成竖比例后模型宽度利用率从 ~52% 提到 ~71%，整组宽度也从 460 收窄到 327。

WebView 侧的适配系数同步从 `0.96` 提到 `0.99`（几乎贴边），见 `assets/live2d/index.html` 的 `fit()`。
### 数字人渲染引擎可切换

数字人有两种渲染后端，可在「双机联动播报 → 数字人 → 模型与展示 → **渲染引擎**」里切换：

| 后端 | 实现 | 平台 | 状态 |
| --- | --- | --- | --- |
| **WebView**（默认） | WebView + PIXI + Cubism Web SDK | 全平台 | ✅ 稳定，长期验证 |
| **原生** | Cubism Native SDK + OpenGL ES 2（`flutter_live2d`） | Android / iOS | ✅ 可用（构建前需跑补丁脚本，见下节） |

- 选择会记住（`prompt_avatar_backend`），重启后保持
- 切换后数字人立即按新后端重新加载，模型/嘴型/导入逻辑完全复用
- **当前平台不支持的后端会置灰**（如 Windows 上的原生渲染 —— `flutter_live2d` 只声明了 Android / iOS）

**原生后端踩过的坑（5 个，全部已修）**

上游插件的 3 个（详见后文「两个上游 bug 与修复」一节，实际是 3 个）：GL context 初始化时机、shader 未打进 APK、`SetWidth` 导致瘦高模型裁成半身。

我们这边的 2 个：

1. **`Live2DView` 必须始终在 widget 树里** —— 插件的 controller 靠视图挂载才 `_attach()`，`whenAttached` 才 resolve；按加载状态决定是否渲染它会造成死锁
2. **加载中不要上报错误** —— 一旦上层用错误框替换掉 `Live2DView`，插件立即 detach，后续 `loadModel` 全部 `VIEW_NOT_ATTACHED`
3. **`SurfaceTexture` 是异步创建的** —— 视图刚挂载时原生侧 `width=0`，`nativeLoadModel` 会直接失败，需要重试（已加 4 次重试）

代码结构：

```
lib/services/avatar_renderer.dart                    # AvatarRenderer 抽象 + AvatarBackend 枚举 + 平台可用性
lib/widgets/live2d_avatar.dart                       # 壳：按后端创建 renderer，转发嘴型
lib/widgets/renderers/webview_avatar_renderer.dart   # WebView 实现
lib/widgets/renderers/native_avatar_renderer.dart    # 原生实现
```

**代价**：APK +4MB（Cubism Core 静态库），Android 构建需要 CMake 3.10.2 + NDK 27.2（CI 已自动安装）。

### 液态玻璃风格（Liquid Glass）

新增 `lib/widgets/glass_surface.dart`，提供统一的玻璃质感组件：

| 组件 | 用途 |
| --- | --- |
| `GlassSurface` | 玻璃容器：背景强模糊（BackdropFilter）+ 半透明渐变 + 1px 高光描边 + 柔和投影 |
| `GlassNavBar` | 悬浮玻璃导航条（联动页底部） |
| `GlassNavItem` | 导航项，选中时是更亮的一小块玻璃 |
| `GlassActionButton` | 悬浮玻璃主按钮（首页「开始拨号」「选择 Excel 文件」） |

- 联动页底部标签栏从「占布局空间」改成**悬浮在内容之上**的玻璃条（内容区留了 96px 底部空白，不会被遮住）
- 首页的主操作按钮也改成悬浮玻璃按钮（列表里不再有重复的大按钮）
- 玻璃模糊需要背后有内容才看得出来，所以两个页面都把按钮放在内容之上（`Stack` + `Positioned`），而不是放在 `bottomNavigationBar`

### 页面布局（尽量不滚动就能操作）

「双机联动播报」页改成 **常驻快捷条 + 4 个标签页**：

| 位置 | 内容 |
| --- | --- |
| 常驻快捷条 | 拨号端 / 播放端**胶囊开关**（点一下切换）、连接状态与「连接拨号端」按钮、**「立即播报」**主按钮；无障碍未开启时额外出现「开启检测」快捷入口 |
| 连接标签 | 通话检测服务（无障碍状态 + 跳转设置）、设备名、单机自测 |
| 播报标签 | 开场白文本 + 语速、端侧语音合成、开场白音频 |
| 数字人标签 | 数字人开关、模型与展示（切换模型 / 导入 zip / 演示模式 / 复位位置） |
| 日志标签 | 运行日志、使用要点 |

- 角色开关从长列表挪成了顶部小胶囊，**不用滚动**就能开关角色、连对端、立即播报
- 每个标签页内部仍可滚动，但首屏就能看到该页的主要操作
### 使用步骤

1. 两台手机连**同一个 Wi-Fi**，都安装本应用
2. 打开应用右上角 🎤 图标进入「双机联动播报」
3. **所有角色默认都是关闭的**，按需打开（开关状态会被记住，下次打开 App 自动生效）：
   - **拨号端**：打开「拨号端：接通后自动通知播放端」，并点「打开系统无障碍设置」→ 找到「话务助手」→ 开启
     （未开启时页面顶部会显示橙色「未开启」，接通检测不会工作）
   - **播放端**：打开「播放端：收到指令后朗读开场白」，把音量调到 60~80%
4. **设置开场白**（二选一，**推荐音频**）：
   - 点「开场白音频 → 选择音频文件」，录一段真人开场白（mp3/wav/m4a/ogg）导入，播报时优先播放它
   - 或者用「开场白文本」交给系统 TTS 朗读（部分 ROM 的 TTS 不对第三方开放，见下方注意事项）
   - 想用端侧合成：在「端侧语音合成」卡片里点**模型下载链接（可点击跳转）**下载 `vits-piper-zh_CN-xiao_ya-medium-int8.tar.bz2`（13.4MB），传到手机后点「导入模型包」，再点「生成语音」
5. 回名单页正常拨号；对方接通后播放端会自动朗读/播放

### 开关与配置持久化

| 开关 | 默认 | 记忆方式 | 打开后自动初始化 |
| --- | --- | --- | --- |
| 拨号端 | **关** | `SharedPreferences` | 局域网通道 + 通话状态监听（无障碍检测接通） |
| 播放端 | **关** | `SharedPreferences` | 局域网通道（接收播报指令） |
| 数字人 | **关** | `SharedPreferences` | Live2D 资源释放 + 本地 HTTP 服务（否则模型会 404） |

- 角色与数字人开关**默认全部关闭**，首次安装不会自动跑任何后台服务
- 手动改过之后配置会**固化**，下次打开 App 自动按配置初始化对应服务（关掉的角色不监听 47823 端口、也不订阅无障碍事件）
- 两个角色都关着时 App 不占端口、不订阅通话状态，省电也少权限

> **为什么推荐音频文件**：实测小米 HyperOS 的系统 TTS（`com.xiaomi.mibrain.speech`）不对第三方应用开放，`TextToSpeech` 初始化直接返回 `-1`，App 无法让系统引擎发声。换成真人录音播放，既绕过引擎限制，声音也更自然、更不容易被听出是合成的。

### 端侧语音合成（C+A 混合，文本驱动 + 零播报延迟）

既想「文本可改」又不想依赖系统 TTS，可以让 App 用内置的 sherpa-onnx **离线合成一次**，把开场白变成 wav 缓存下来，之后每次接通只播 wav：

```
编辑开场白文本 → 点「生成语音」（本机合成 2 秒左右，只做一次）
        ↓
   缓存 opening_tts_<ts>.wav（自动设为播报音频）
        ↓
接通 → 广播 → 播放端直接播 wav（延迟 ≈ 0，不等合成）
```

**安装模型（一次性，13.4MB）**

1. 下载 `vits-piper-zh_CN-xiao_ya-medium-int8.tar.bz2`（13.4MB）
   <https://github.com/k2-fsa/sherpa-onnx/releases/tag/tts-models>
2. 把 `.tar.bz2` 传到手机
3. App 内「双机联动播报 → 端侧语音合成 → 导入模型包」，选这个文件
4. 状态变为「模型就绪」后，点「生成语音」即可

模型解压到 `Android/data/com.callassistant.call_assistant/files/sherpa-tts/`（可用 adb 直接推），也可手动放模型目录后重启 App 自动识别。

**实测数据（小米 2410DPN6CC / Android 17）**

| 环节 | 耗时 |
| --- | --- |
| 解压 13.4MB 模型包 | ~1.0 s |
| 首次合成（含模型加载，约 24 字） | ~2.1 s |
| 后续合成（模型常驻） | 明显更快 |
| 播报时（播 wav） | 启动 < 100 ms |

> 生成的是 16bit PCM 单声道 wav，语速由文本卡的「语速」滑块换算成 `speed` 参数。模型只在合成时用到，**不打包进 APK**。

### 数字人说话口型（Live2D）

播报时界面上会有一个 Live2D 数字人做说话口型，嘴型与语音音量严格同步（只在本机屏幕可见，对方在通话里看不到画面）。

**浮窗结构（上：角色 + 操作栏，下：话术框）**

```
展开态                                  贴边态（微信通话「最小化」）
┌────────────────┐ ┃⠿ ┃  拖动          ┌──┐
│                │ ┃‹ ┃  上一步         │🧑│ ← 小挂件 + 状态圆点
│     角色        │ ┃› ┃  下一步         │  │   + 恢复按钮 ↗
│  （占屏幕一半）  │ ┃💬 ┃  话术框收起     └──┘
│                │ ┃⇱ ┃  贴边            点它/拖它即恢复
│                │ ┃✕ ┃  关闭           （贴屏幕左/右边缘）
└────────────────┘
┌────────────────┐
│ ● 等待接通 · 张伟 │  ← 状态信息在话术框顶部
│ ─────────────── │
│ 张伟    今天16:15拨过│
│ 销售一部           │
│ 话术 1/1           │
│ 您好，我是本次项目…  │
└────────────────┘
```

- **上下结构**：上半部分「角色 + 右侧操作栏」，下半部分话术框（宽度与上方**完全对齐**，左边缘和右边缘都齐）
- **整体宽度约占屏幕 80%**（`groupRatio = 0.8`，限制在 240~460 之间），角色随之放大到约 1.6 倍；Live2D 模型本身左右留白较多，想再大就把 `groupRatio` 往 1.0 调
- **操作栏垂直居中**于角色右侧（高度自适应，不与角色等高）
- **话术框可单独收起/展示**：操作栏上的 `💬` 按钮切换，收起后只剩角色 + 操作栏（图标变为空心气泡表示可展开）；状态本地持久化
- **状态条并入话术框**：话术框第一行就是状态（`待拨号`/`等待接通`/`播报中`/`异常`，带颜色圆点），不再单独占一条
- **贴边收起**（微信通话「最小化」样式）：点 `⇱` 或把浮窗拖到屏幕左右边缘，会缩成 116×146 的小挂件贴在边缘，只露出角色 + 状态圆点 + 恢复按钮；**点挂件或直接拖动它就恢复原样**（恢复后回到原位置）
- **提词气泡**：拨号时自动带上客户名、单位/备注（取表格前两个字段）、上次拨打时间（`今天 15:30 拨过` / `3 天前拨过` / `首次联系`），以及**按句拆好的话术步骤**
- 位置自动记忆；贴边方向按浮窗所在的一侧自动判断

**演示模式（全屏，适合录屏/给客户看）**

联动页右上角数字人菜单 →「演示模式（全屏）」：与联动页同色背景 + 放大一倍的大尺寸数字人（几乎占满可用高度）+ 逐句字幕 + 进度条，话术框固定高度（**至少能显示 4 行**），点「开始演示」按话术播报，字幕按播报时长自动推进（有合成音频时按其真实时长，否则按字数估算）。右上角可切模型。

**浮窗与拖动**

- 数字人是**全局浮层**（挂在 `MaterialApp.builder` 上），因此浮在所有页面之上：首页、名单列表、联动配置页都能看到，不随页面滚动
- **背景完全透明**：没有底板、没有阴影，只画角色本身，页面文字可以透过角色周围正常阅读
- 按住数字人**底部的小胶囊拖动条**即可拖到屏幕任意位置（自动夹在可视区域内），松手后位置写入本地，**重启仍保持**
- 胶囊右侧的 **✕** 直接关闭（等同关掉联动开关）；卡片里的「复位」按钮回到默认右上位置
- 尺寸固定 300×380（+40 控制条），便于看清模型细节；想调小改 `FloatingAvatarHost.avatarWidth/avatarHeight`
- 平台视图（WebView）会吃掉自身范围内的触摸，所以拖动条与 ✕ 都放在视图**外面**；角色身体覆盖到某个按钮时，把它拖开即可
- 实现上两个坑：① `Live2dAvatar` 不能自带底色、也不能套 `IgnorePointer`（会让 Android 层把这一带触摸直接派给 WebView，连控制条都点不动）；② 必须保留 `ClipRect` 约束平台视图的触摸区域

**实现方式**

| 环节 | 做法 |
| --- | --- |
| 渲染 | `webview_flutter` + `pixi-live2d-display` + Cubism 5 Core（打包在 `assets/live2d/`，5.4MB） |
| 托管 | `file://` 下 WebView 的 `fetch` 会被 CORS 拦，因此把资源释放到应用目录后用 `127.0.0.1` 静态服务托管（`Live2dService`） |
| 唇形 | 合成 wav 时顺带算振幅包络（每 50ms 一个 RMS 值，存 `*.wav.env.json`）→ 播放时按播放位置查表 → JS 设置 `ParamMouthOpenY` |
| 平滑 | JS 侧按帧向目标值插值（0.35 系数），避免嘴型跳动 |
| 兜底 | 没有包络（用户自选 mp3/ogg）或走系统 TTS 时，用正弦+随机包络的程序化口型 |

**模型**

内置 **8 个 Live2D 官方样例模型**（`assets/live2d/`，共约 22MB），右上角数字人菜单 →「切换已有模型」即可逐个试：

| 目录 | 模型 | 体积 | 备注 |
| --- | --- | --- | --- |
| `haru/` | Haru | 3.1 MB | 带 8 个表情（expressions） |
| `hiyori/` | Hiyori | 4.7 MB | **默认**，10 个动作 |
| `mao/` | Mao | 4.1 MB | 带表情 |
| `mark/` | Mark | 0.7 MB | 体量最小，风格化角色 |
| `natori/` | Natori | 3.3 MB | 带表情（`exp/`） |
| `rice/` | Rice | 3.0 MB | 小动物风格 |
| `wanko/` | Wanko | 0.7 MB | 1024 贴图 |

> **授权提醒**：这些都是 Live2D 官方样例模型，**仅允许测试/非商业用途**，对外发布必须替换成自有或已购买授权的模型。

> **关于 Cubism 3 格式的模型**：内置运行时是 Cubism 5 Core，只支持 **moc3 v5 及以下**（= Cubism 4/5）；Cubism 3 的模型是 **moc3 v6**，且官方运行时早已移除 Cubism 3 实现、Cubism 3 Core 也不再公开分发，因此**这类模型无法加载**（官方样例里的 Ren 就属于这一类，已从内置列表移除）。App 仍会按 **moc 文件头版本号**自动过滤这类模型，万一手动指定了它，页面会给出明确提示而不是英文报错。
> 判据是 **moc 文件头的版本号**（不是 model3.json 里的 `Version`——那个字段 Cubism 4 也是 3）。

- 自备模型：打包成 zip（内含 `*.model3.json` 及贴图/动作/表情文件）→ 数字人菜单 →「导入模型包（zip）」→ 释放到 `Android/data/<包名>/files/live2d/models/<名字>/`
- 首次启动会把 assets 里的运行时与模型解压到应用目录（约 22MB，`Live2dService.assetVersion` 控制是否重新释放）
- 想换默认模型：改 `Live2dService.defaultModel`（如 `haru/Haru.model3.json`）

**实测（小米 2410DPN6CC / Android 17）**

```
[Live2D] mouth=0.52 smooth=0
[Live2D] mouth=0.52 smooth=0.16
[Live2D] mouth=0.17 smooth=0.31
[Live2D] mouth=0.64 smooth=0.48
```

`smooth` 是模型里实际生效的 `ParamMouthOpenY`，会平滑跟随包络目标值，说明唇形链路正常。

**已知限制**

- **WebView 是平台视图（混合合成），会遮挡紧邻的 Flutter 控件** —— 所以「导入模型」「切换模型」放在标题栏菜单
- 浮层位于 Navigator 之上，因此打开对话框 / 底部面板时数字人依然浮在最上面（把它理解成桌面挂件即可）；不想要就点 ✕ 关掉
- **演示模式（全屏）会自动隐藏浮窗**，避免出现两个角色并挡住字幕
- 个别 ROM 的 WebView 若关闭 WebGL，会显示「数字人加载失败」，功能不受影响（只影响动画）
- 数字人只在本机屏幕上，通话对方看不到；要做给客户看的画面需要视频通话/录屏，是另一套方案

### 浮窗踩过的三个坑（改代码前先看这里）

1. **必须让浮窗「点击穿透」**：平台视图（WebView）本身会吃掉它覆盖区域的全部点击；`Material` / 带 `decoration` 的 `Container` / `ClipRect` 同样会吃点击。做法是：角色区、状态条、气泡统统 `IgnorePointer`，控制条保持可交互；`Live2dAvatar` 里的 `IgnorePointer` 必须包在 `ClipRect` **外面**。
2. **必须有 `DefaultTextStyle`**：浮层挂在 `MaterialApp.builder` 上、没有 `Material` 祖先，文字会落到 Flutter 的 fallback 样式（标志性的**红字 + 黄色双下划线**）。用 `DefaultTextStyle(style: Theme.of(context).textTheme.bodyMedium!)` 包一层即可。
3. **平台视图走的是纹理合成**（`displayWithHybridComposition` 默认 false），命中测试由 Flutter 决定，所以 `IgnorePointer` 才有效。
4. **放进 `Row` 后要给固定宽度**：`Row` 的非 flex 子节点拿到的是**无界宽度**，`Live2dAvatar` 里的 `width: double.infinity` 会变成无限宽，平台视图直接渲染不出来（现象：只剩气泡、角色消失）。外面套一层 `SizedBox(width: 300)` 即可。

### 关键注意事项

| 项 | 说明 |
| --- | --- |
| 接通判定 | 依赖通话界面的计时器/「通话中」文案，**不同 ROM 界面不同**，已在代码里按包名过滤（dialer / incallui / contacts / phone / call），个别机型可能需要调整匹配规则 |
| 系统 TTS | 小米 HyperOS 的引擎对第三方关闭绑定（`TextToSpeech` 初始化 `status: -1`），此时必须用「开场白音频」；Android 原生/多数 ROM 用 `adb shell settings get secure tts_default_synth` 可查看默认引擎 |
| 强制停止 | **MIUI/HyperOS 上「强制停止」应用会被系统移除无障碍授权**，需要在设置里重新开启。已用**前台保活服务**规避：拨号端开启时 App 会常驻前台服务，进程不会被系统回收（实测 `am kill` 杀不掉），授权不会自己掉。仍被用户手动「强制停止」的话只能重新授权 |
| 自检方法 | 接不上时先看页面底部「运行日志」：`已连接拨号端` = 播放端已连上；`检测到接通` = 无障碍生效；`收到播报指令` = 播放端收到；`开始播放音频` = 音频已触发。日志只在**连接/断开**时记录，不会被心跳刷屏 |
| 降噪干扰 | 拨号手机若开启「AI 通话降噪 / 人声增强」，可能削弱播放端的外放声，建议关闭 |
| 拾音位置 | 开免提时麦克风在底部，关免提时在上部，播放端要对准对应麦克风 |
| 后台存活 | 系统省电策略建议设为「无限制 / 允许后台运行」，否则通话中进程被回收会导致检测中断 |
| 端口 | UDP `47823`；路由器若屏蔽 255.255.255.255 广播，会自动改为向已发现对端单播 |

**连接方式（播放端主动发起）**

```
播放端点「连接拨号端」
   └─ 广播 query（每 2 秒重试，最多 15 次）
        └─ 拨号端收到 query → 回 hello（role=dialer）
             └─ 播放端收到 hello → 单播 connect
                  └─ 拨号端回 connected → 双方标记「已连接」
```

- **不需要双方都开**：拨号端只要开着就在线，播放端点一下按钮就能连上
- 日志只在**连接成功/断开**时记录一条，心跳不会刷屏
- 15 秒收不到对端任何消息 → 自动判定断开并记一条「已断开连接」
- 连接建立后，接通指令、播报都走这条已建立的通道

**单机自测（只有一台手机时）**

联动页 →「单机自测」打开后，**本机同时扮演拨号端与播放端**：自己收自己的广播、自动完成握手，状态行显示「已连接：<本机名>」。这样不用第二台手机就能验证整条链路（接通 → 广播 → 朗读 → 口型）。
| 隐私 | 只读取通话界面上的计时文案，**不上传、不录音**；无障碍服务描述中已声明 |

### 后续可升级方向

- 接通检测换成 **默认拨号应用**（`InCallService` + `ROLE_DIALER`）→ 拿到准确的 `Call.STATE_ACTIVE`，兼容性远好于读界面
- 播报改为**服务器侧外呼**（语音通知/呼叫中心）→ 无需第二台手机，音质与合规性最好
- 播放端改用预生成音频文件（去掉 TTS 首次发声延迟）

## CI 自动发布 APK（GitHub Actions）

工作流：`.github/workflows/apk.yml`，两个 job：

| Job | 触发 | 产物 |
| --- | --- | --- |
| `ci` | push 到 main / PR / 手动触发 | 分析 + 测试 + Debug APK（Artifact，保留 14 天） |
| `release` | **打 `v*` 标签时** | 正式签名 APK（按 ABI 拆分，**只发布 ARM 架构**），重命名为 `call-assistant-版本号-架构.apk`，并创建 GitHub Release |

流程（release job）：checkout → JDK 21 + Flutter → 从 Secrets 还原密钥 → `flutter pub get` → 校验标签版本与 pubspec 版本一致 → `flutter build apk --release --split-per-abi` → 只保留 ARM 架构并重命名 → 创建 GitHub Release。

发布产物（以 v1.1.0 为例）：

| 文件名 | 体积 | 适用设备 |
| --- | --- | --- |
| `call-assistant-1.1.0-arm64-v8a.apk` | ~63.6 MB | 绝大多数现代手机（**推荐**） |
| `call-assistant-1.1.0-armeabi-v7a.apk` | ~53.2 MB | 32 位老旧机型（Android 5~7 时代） |

- 用 `--split-per-abi` 拆分后每个包只含一套 so；`x86_64` 仅用于模拟器，不发布
- 体积比早期版本（17.5MB）大，是因为内置了离线 TTS 引擎（sherpa-onnx + onnxruntime，约 26MB so）与 Live2D 运行时 + **8 个官方样例模型（约 22MB assets）**；通用包会到 145MB，所以**必须按 ABI 拆分**
- 只想带一个模型时：从 `pubspec.yaml` 的 `assets:` 里删掉其它模型目录，并同步清理 `assets/live2d/` 下对应文件夹（每个模型约 0.7~4.7MB）
- 两个包共用同一签名密钥，可互相覆盖安装

> 标签推送时 `ci` job 会被跳过（不重复构建），只跑 `release`；普通 push 只做 CI 校验，不产出安装包。

### 一次性准备

1. **生成签名密钥**（在本机执行，密钥不会提交到仓库）：

   ```powershell
   pwsh -File tool/make_keystore.ps1
   ```

   会生成 `android/app/upload-keystore.jks` 和 `android/key.properties`（两者均已在 `.gitignore` 中），并在终端打印 4 个 Secret 的值。

2. **在 GitHub 添加 4 个 Secret**：仓库 `Settings → Secrets and variables → Actions → New repository secret`

   | Secret | 内容 |
   | --- | --- |
   | `KEYSTORE_BASE64` | 脚本打印的 base64 串（整行） |
   | `KEYSTORE_PASSWORD` | 脚本打印的 keystore 密码 |
   | `KEY_ALIAS` | 脚本打印的别名（默认 `upload`） |
   | `KEY_PASSWORD` | 脚本打印的 key 密码 |

3. **打标签发布**：

   ```powershell
   # 先把 pubspec.yaml 里的 version 改成要发布的版本号并提交
   # version: 1.1.0+2  ->  版本号取 1.1.0
   git add pubspec.yaml && git commit -m "chore: bump version to 1.1.0"
   git push origin main
   git tag v1.1.0
   git push origin v1.1.0
   ```

   标签推送后 `release` job 会跑，校验标签版本与 `pubspec.yaml` 版本一致（不一致直接报错终止），构建正式签名包并重命名为 `call-assistant-1.1.0.apk`，挂到 GitHub Release 上。

### 说明

- JDK 21（Temurin）+ Flutter 3.47.7 + Gradle 缓存，CI 与本地环境一致
- 仓库默认配置了国内镜像（本地网络需要），CI 会自动切回官方源（runner 在海外，官方源更快更全）
- `android/app/build.gradle.kts` 已改为：存在 `key.properties` 就用正式签名，否则回退 debug 签名
- **发布 job 强制要求配置了签名 Secret**：缺少 `KEYSTORE_BASE64` 会直接报错终止，避免误发出 debug 签名的包
- 密钥务必备份，丢失后无法给已发布应用做更新

## 常见问题

| 现象 | 处理方式 |
| --- | --- |
| `adb install` 报 `INSTALL_FAILED_USER_RESTRICTED` | 手机未允许「USB 安装 / 未知来源安装」，在 设置 → 开发者选项 里打开，或安装弹窗时在手机上确认 |
| 提示「无法解析该文件」 | 只支持 `.xlsx`；`.xls` / `.csv` 请在 Excel 里另存为「Excel 工作簿(*.xlsx)」 |
| 手机号列识别错了 | 首页「手机号列」区域点选正确的列 |
| 点号码没反应 | 检查 Manifest 里的 `<queries>`；部分定制系统需要设置里允许本应用「拨打电话」 |
| 号码变成 `1.38E+11` | 原始表格里把该列设为「文本」，本应用已做科学计数法兜底，但仍建议在 Excel 侧固定为文本 |
| 录音/一键外呼需求 | `tel:` 只填充不外呼；要一键外呼需改用 `flutter_phone_call` 或原生 `ACTION_CALL` 并申请 `CALL_PHONE` 权限 |
