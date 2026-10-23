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
│  └─ prompt_link.dart            双机联动编排（接通→广播→朗读）
├─ utils/phone_utils.dart         号码归一化、类型识别（手机/固话/本地座机）、区号补全
├─ pages/
│  ├─ home_page.dart              导入、参数确认（工作表 / 手机号列 / 统计）
│  ├─ record_list_page.dart       名单列表、搜索、拨号
│  └─ prompt_page.dart            双机联动配置（角色 / 开场白 / 日志）
└─ widgets/record_card.dart       单条记录卡片
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

### 使用步骤

1. 两台手机连**同一个 Wi-Fi**，都安装本应用
2. 打开应用右上角 🎤 图标进入「双机联动播报」
3. **拨号端**：打开「拨号端：接通后自动通知播放端」，并点「打开系统无障碍设置」→ 找到「话务助手」→ 开启
   （未开启时页面顶部会显示橙色「未开启」，接通检测不会工作）
4. **播放端**：只保留「播放端：收到指令后朗读开场白」，把音量调到 60~80%
5. **设置开场白**（二选一，**推荐音频**）：
   - 点「开场白音频 → 选择音频文件」，录一段真人开场白（mp3/wav/m4a/ogg）导入，播报时优先播放它
   - 或者用「开场白文本」交给系统 TTS 朗读（部分 ROM 的 TTS 不对第三方开放，见下方注意事项）
6. 回名单页正常拨号；对方接通后播放端会自动朗读/播放

> **为什么推荐音频文件**：实测小米 HyperOS 的系统 TTS（`com.xiaomi.mibrain.speech`）不对第三方应用开放，`TextToSpeech` 初始化直接返回 `-1`，App 无法让系统引擎发声。换成真人录音播放，既绕过引擎限制，声音也更自然、更不容易被听出是合成的。

### 关键注意事项

| 项 | 说明 |
| --- | --- |
| 接通判定 | 依赖通话界面的计时器/「通话中」文案，**不同 ROM 界面不同**，已在代码里按包名过滤（dialer / incallui / contacts / phone / call），个别机型可能需要调整匹配规则 |
| 系统 TTS | 小米 HyperOS 的引擎对第三方关闭绑定（`TextToSpeech` 初始化 `status: -1`），此时必须用「开场白音频」；Android 原生/多数 ROM 用 `adb shell settings get secure tts_default_synth` 可查看默认引擎 |
| 强制停止 | **MIUI/HyperOS 上「强制停止」应用会被系统移除无障碍授权**，需要在设置里重新开启（普通进程被回收一般不影响） |
| 自检方法 | 接不上时先看页面底部「运行日志」：`发现对端` = 局域网通；`检测到接通` = 无障碍生效；`收到播报指令` = 播放端收到；`开始播放音频` = 音频已触发 |
| 降噪干扰 | 拨号手机若开启「AI 通话降噪 / 人声增强」，可能削弱播放端的外放声，建议关闭 |
| 拾音位置 | 开免提时麦克风在底部，关免提时在上部，播放端要对准对应麦克风 |
| 后台存活 | 系统省电策略建议设为「无限制 / 允许后台运行」，否则通话中进程被回收会导致检测中断 |
| 端口 | UDP `47823`；路由器若屏蔽 255.255.255.255 广播，会自动改为向已发现对端单播 |
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

发布产物（以 v1.0.0 为例）：

| 文件名 | 体积 | 适用设备 |
| --- | --- | --- |
| `call-assistant-1.0.0-arm64-v8a.apk` | ~17.5 MB | 绝大多数现代手机（**推荐**） |
| `call-assistant-1.0.0-armeabi-v7a.apk` | ~15 MB | 32 位老旧机型（Android 5~7 时代） |

- 用 `--split-per-abi` 拆分后每个包只含一套 so，相比通用包（49.3MB）体积小一半以上
- `x86_64` 仅用于模拟器，不发布
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
   # version: 1.0.0+1  ->  版本号取 1.0.0
   git add pubspec.yaml && git commit -m "chore: bump version to 1.0.0"
   git push origin main
   git tag v1.0.0
   git push origin v1.0.0
   ```

   标签推送后 `release` job 会跑，校验标签版本与 `pubspec.yaml` 版本一致（不一致直接报错终止），构建正式签名包并重命名为 `call-assistant-1.0.0.apk`，挂到 GitHub Release 上。

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