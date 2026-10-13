# 话务助手（call_assistant）

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
│  └─ call_log_store.dart         已呼叫号码本地存储
├─ utils/phone_utils.dart         号码归一化、类型识别（手机/固话/本地座机）、区号补全
├─ pages/
│  ├─ home_page.dart              导入、参数确认（工作表 / 手机号列 / 统计）
│  └─ record_list_page.dart       名单列表、搜索、拨号
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

## 常见问题

| 现象 | 处理方式 |
| --- | --- |
| `adb install` 报 `INSTALL_FAILED_USER_RESTRICTED` | 手机未允许「USB 安装 / 未知来源安装」，在 设置 → 开发者选项 里打开，或安装弹窗时在手机上确认 |
| 提示「无法解析该文件」 | 只支持 `.xlsx`；`.xls` / `.csv` 请在 Excel 里另存为「Excel 工作簿(*.xlsx)」 |
| 手机号列识别错了 | 首页「手机号列」区域点选正确的列 |
| 点号码没反应 | 检查 Manifest 里的 `<queries>`；部分定制系统需要设置里允许本应用「拨打电话」 |
| 号码变成 `1.38E+11` | 原始表格里把该列设为「文本」，本应用已做科学计数法兜底，但仍建议在 Excel 侧固定为文本 |
| 录音/一键外呼需求 | `tel:` 只填充不外呼；要一键外呼需改用 `flutter_phone_call` 或原生 `ACTION_CALL` 并申请 `CALL_PHONE` 权限 |