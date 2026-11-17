# 交接文档 / Handover

> 本文记录当前仓库（`Yhimhas/venera` 的本地 fork）的现状、已做的改动、环境搭建方式、
> 网络诊断结论与后续待办。面向接手继续开发的人。
> 最近更新：2026-11-17（分支 `fix/network`）

---

## 1. 项目与仓库现状

| 项 | 值 |
|---|---|
| 上游 | [venera-app/venera](https://github.com/venera-app/venera)，README 已声明停止维护 |
| 本地 fork | `https://github.com/Yhimhas/venera`，工作目录 `D:\venera` |
| 版本 | `1.6.3+163`（`pubspec.yaml`） |
| 许可 | GPL-3.0 |
| 技术栈 | Flutter **3.41.4**（Dart 3.11.1）+ **Rust 1.85.1**（`rhttp` 的 HTTP 栈）+ QuickJS（`flutter_qjs`，漫画源脚本引擎） |
| 构建产物 | Android APK（arm64 / armv7 / x86_64 / universal）、Windows、Linux(deb/AppImage/AUR)、macOS、iOS |

代码规模：`lib/` 下 135 个 `.dart`，约 4.37 万行。

### 分支状态

```
ab5396c fix(network): detect a failing repository url instead of guessing
e5d7200 perf(network): reuse a single rhttp client for all requests
afe3725 fix(network): survive filtered mirrors and fix source adding
a0eba91 Update README.md                <- master / origin/master
```

* 当前所在分支：`fix/network`（基于 `master@a0eba91`），**没有 push**。
* `master` 仍指向 `a0eba91`，未合并。

---

## 2. 目录与关键代码位置

```
lib/
  main.dart                     入口：--headless / 桌面窗口 / MaterialApp
  init.dart                     启动初始化（Rhttp.init、数据加载、默认值迁移）
  foundation/
    app.dart                    App.dataPath / externalStoragePath / isDesktop
    appdata.dart                设置项与默认值（settings map）、appdata.json 读写
    comic_source/
      comic_source.dart         漫画源管理（加载/更新/排序）
      parser.dart               漫画源 JS 解析（41KB，最大的解析层）
      source_repo.dart          ★ 本次新增：仓库镜像候选 / 竞速 / 回退
    js_engine.dart              Dart ↔ QuickJS 桥、crypto、cookie/proxy 注入
  network/
    app_dio.dart                ★ AppDio + RHttpAdapter（rhttp 适配、连接复用）
    retry.dart                  ★ 本次新增：GET 重试（指数退避）
    proxy.dart                  代理字符串解析/归一化 + 缓存失效
    cloudflare.dart             Cloudflare 验证拦截
    cache.dart / cookie_jar.dart / images.dart / download.dart
  pages/
    comic_source_page.dart      ★ 漫画源列表 / 添加源 / 检查更新
    settings/network.dart       ★ 网络设置：代理（http/https/socks5 + 测试）、DNS 覆写
    reader/                     阅读器
docs/                           已有：comic_source.md、js_api.md、headless_doc.md、import_comic.md、本文
                                （注：上游原目录名为 doc/，本 fork 已改名为 docs/，README 里的 doc/ 链接尚未同步）
assets/init.js                  漫画源脚本宿主 API（1393 行）
```

### 数据与日志路径（Android）

| 内容 | 路径 |
|---|---|
| 设置 / 数据库 / 已装源 | `/data/data/com.github.wgh136.venera/files/`（`appdata.json`、`*.db`、`comic_source/*.js`） |
| 运行日志 | `/storage/emulated/0/Android/data/com.github.wgh136.venera/files/logs.txt` |

> ⚠️ `logs.txt` 用 `File.openWrite()` 打开，**App 每次冷启动都会截断**，排查问题时先把日志拉下来。

---

## 3. 开发环境（已搭好，位于 WSL2）

宿主：Windows 11 + WSL2 `Ubuntu 26.04`（32 核 / 11G 可用 / D 盘余量足够）。

| 组件 | 版本 / 位置 |
|---|---|
| Flutter | 3.41.4 stable，`~/sdks/flutter`（`flutter doctor` 的 Android toolchain ✓） |
| JDK | Temurin **17.0.21**，`~/sdks/jdk17`（系统自带 JDK 25 与 AGP 不兼容，勿混用） |
| Android SDK | `~/sdks/android-sdk`：platform **android-36**、build-tools **36.0.0**、NDK **28.0.13004108**、cmake 3.22.1 |
| Rust | 1.85.1（`~/.cargo`），targets：`aarch64-linux-android`、`armv7-linux-androideabi`、`x86_64-linux-android`（+ 两个 apple target） |
| adb | Windows 侧 `D:\tools\platform-tools\adb.exe` |

### 从零复现环境

```bash
wsl -d Ubuntu -- bash /mnt/d/venera-dist/setup_flutter.sh   # Flutter 3.41.4 + pub get
wsl -d Ubuntu -- bash /mnt/d/venera-dist/setup_android.sh   # JDK17 + SDK/NDK + Rust targets
wsl -d Ubuntu -- bash /mnt/d/venera-dist/make_keystore.sh   # 生成签名 + android/key.properties（只需一次）
wsl -d Ubuntu -- bash /mnt/d/venera-dist/build_apk.sh       # 构建 arm64 release APK
```

脚本在 `D:\venera-dist\`（不在仓库内，避免污染版本库）。

### 签名

`android/app/build.gradle` 会**无条件**读取 `android/key.properties`，文件不存在则 Gradle 配置阶段直接失败。
本地已生成：

```
android/key.properties
    storePassword=veneradev
    keyPassword=veneradev
    keyAlias=venera
    storeFile=/home/lin/sdks/venera-dev.jks
```

`android/.gitignore` 已忽略 `key.properties` 与 `*.jks`，**不会进版本库**；也请不要把官方 release keystore 放进来。

### 构建注意

* `flutter build apk --release --target-platform android-arm64` 只出 arm64，最快；全量产物在
  `build/app/outputs/flutter-apk/`。
* versionCode 规则：`versionCode * 10 + abiCode`（arm64=2），所以 163 → `1632`。
* WSL 内 **`maven.google.com` 被阻断（超时）**，但 Gradle 的 `google()` 走的是
  `https://dl.google.com/dl/android/maven2/`，实测可达，构建正常。
  若日后换网络仍失败，可在 `~/.gradle/init.gradle` 加阿里云镜像：
  `https://maven.aliyun.com/repository/google`、`.../public`（实测 200）。
* WSL 内 **无法**访问 Windows 上的 `127.0.0.1:7897`（mihomo 只监听回环），需要代理时先给 mihomo 开
  “允许局域网”，或用 WSL 镜像网络模式。

---

## 4. 测试设备

| 项 | 值 |
|---|---|
| 型号 | `M2007J3SC`（Redmi），Android **12**（SDK 31），arm64-v8a |
| 连接 | 无线 adb `192.168.10.206:42165` |
| Root | **Magisk 已 root**（`su` 可用），另有 LSPosed |
| 包名 | `com.github.wgh136.venera` |

### 装包的两个坑

1. **MIUI 拦截 adb 安装**：直接 `adb install` 报 `INSTALL_FAILED_USER_RESTRICTED`（“Install canceled by user”）。
   有 root 时的可靠做法：
   ```powershell
   adb -s 192.168.10.206:42165 push app-arm64-v8a-release.apk /data/local/tmp/v.apk
   adb -s 192.168.10.206:42165 shell "su -c 'pm install -r -d /data/local/tmp/v.apk'"
   ```
   （`/sdcard` 不能作为 `pm install` 的来源，走 `pm install-write` 也会被 SELinux 拒绝，用 `/data/local/tmp`。）
2. **签名不一致**：本地构建与官方包签名不同，覆盖安装报 `INSTALL_FAILED_UPDATE_INCOMPATIBLE`。
   先 `su -c 'pm uninstall com.github.wgh136.venera'`（会清数据），或日后统一改用官方 keystore。

### 常用调试命令

```powershell
$d='192.168.10.206:42165'
# 截图（注意：直接 pwsh 重定向会破坏 PNG，用 screencap 落盘再 pull）
adb -s $d shell "su -c 'screencap -p /sdcard/s.png'"; adb -s $d pull /sdcard/s.png .\s.png
# 点击/输入/返回（MIUI 下 adb 直连 input 会被 INJECT_EVENTS 拒绝，必须 su）
adb -s $d shell "su -c 'input tap 540 1200'"
adb -s $d shell "su -c 'input text https://example.com/a.js'"
adb -s $d shell "su -c 'input keyevent 4'"
# 读界面文字（判断输入框实际内容）
adb -s $d shell "su -c 'uiautomator dump /data/local/tmp/ui.xml'"; adb -s $d pull /data/local/tmp/ui.xml .
# 看日志
adb -s $d shell "su -c 'tail -c 4000 /storage/emulated/0/Android/data/com.github.wgh136.venera/files/logs.txt'"
# 冷启动
adb -s $d shell "su -c 'am force-stop com.github.wgh136.venera'"
adb -s $d shell "monkey -p com.github.wgh136.venera -c android.intent.category.LAUNCHER 1"
```

---

## 5. 网络诊断结论（重要）

在该手机所在的国内网络实测（root shell + curl，同一 WiFi）：

| 目标 | 结果 | 说明 |
|---|---|---|
| `cdn.jsdelivr.net`（151.101.129.229） | **TLS reset** | 按 SNI 封锁 |
| `fastly.jsdelivr.net`（**同一 IP**） | 200 | 只是域名不同 |
| `gcore.jsdelivr.net` / `testingcf.jsdelivr.net` | 200 | Cloudflare IP |
| `quantil.jsdelivr.net` | 200 | |
| `raw.githubusercontent.com` | TLS reset | |
| `github.com`（页面/大文件） | 超时 | |
| `1.1.1.1` DoH | 超时 | |
| `www.copy20.com`（拷贝漫画站） | TLS reset | 该源在国内基本不可用 |
| `api.copy-manga.com` | 200 | 同源的 API 域名却正常 |
| `komiic.com` | **TLS reset**（2026-11-17 观察到） | 该源需代理 |
| `www.baidu.com` | 200 | 对照组 |

结论：**同 IP 不同 SNI 一个 reset 一个 200 → 域名（SNI）级封锁**。PC 上一切正常是因为挂着本地 mihomo
（`127.0.0.1:7897`），并不是网络更好。

App 原始默认仓库地址是 `cdn.jsdelivr.net/.../venera-configs@main/index.json`，于是：
进入“漫画源列表”空白、点“添加”必然失败——这就是最初的“网络问题”。

---

## 6. 已完成的改动（`fix/network` 分支）

### 6.1 `afe3725` fix(network): survive filtered mirrors and fix source adding

| 改动 | 说明 |
|---|---|
| 新增 `lib/foundation/comic_source/source_repo.dart` | 从配置地址推导候选镜像（jsdelivr 5 个 host + `raw.githubusercontent.com` 等价地址），index **并发竞速**取最快成功者，脚本**按序回退** |
| 默认地址改 `fastly.jsdelivr.net` | `lib/foundation/appdata.dart`；`lib/init.dart` 增加老配置迁移（`cdn.jsdelivr.net` → `fastly`） |
| 修“改完地址当场点添加必失败” | `_ComicSourceListState` 之前用 `appdata.settings['comicSourceListUrl']`（弹窗 dispose 才落盘），改为使用**实际成功拉列表的 URL** |
| 修加载框卡死 | `handleAddSource` / `ComicSourcePage.update` 的 catch 分支先 `close()` 再报错 |
| 错误信息不再被吞 | 列表加载失败带出真实异常 |
| 新增 `lib/network/retry.dart` | 仅对 **GET** 的 `reset / timeout / handshake` 类错误重试 3 次（400ms、800ms 退避），非幂等请求不重试 |
| 代理能力 | 支持 `http` / `https` / `socks5`（rhttp 走 `reqwest::Proxy::all`，rust 侧已启 `socks` feature）；兼容旧的 `host:port`；保存后失效代理缓存；新增“测试连接”按钮 |

### 6.2 `e5d7200` perf(network): reuse a single rhttp client for all requests

`Rhttp.request(settings: ...)` 每次都会 `RequestClient::new(settings)`，而**原生 client 才持有连接池与
TLS session 缓存**，等于每个请求都要重新握手（在被 reset 的网络里代价更大）。

* `RHttpAdapter` 内常驻一个 `RhttpClient`，请求全部走它；
* 仅在 **proxy / sni / 证书校验 / DNS 覆写**变化时重建并 dispose 旧的；
* 并发创建用 `_pendingClient` 去重；
* `close()` 故意不再释放共享 client（`AppDio` 到处 `new`，否则会把全局池拆掉）；
* 顺手修 `prevent-parallel` 锁：原先 20ms 轮询且在非持锁请求的 `finally` 里**误删别人的锁**，改为每 url 一个 `Completer`。

实测（手机，连续请求同一 index）：**~270ms → ~95ms**。

### 6.3 `ab5396c` fix(network): detect a failing repository url instead of guessing

`SourceRepo.load` 原先调用自带镜像回退的 `fetchText`，因此“配置地址失败”永远探测不到；且镜像竞速
可能比配置地址更快，导致**把最快的镜像当成你的仓库地址存下来**（实测地址漂到 `quantil.jsdelivr.net`）。

* 拆出 `_fetchIndexExact` / `_getTextExact`：单地址请求，失败即抛；
* 竞速只在**配置地址确实失败**时才回写并提示“已切换到镜像 @n”。

### 6.4 验证记录

| 场景 | 结果 |
|---|---|
| 默认 fastly，点刷新 | 33 个源正常加载，地址不漂移 |
| 改成被封锁的 `cdn.jsdelivr.net` → 刷新 | 自动回写 `fastly.jsdelivr.net`，toast「已切换到镜像 fastly.jsdelivr.net」 |
| 用被封锁的 cdn URL 直接加源 | 成功落盘 `komiic.js`（日志可见 cdn reset → 镜像接管） |
| 代理页 http/https/socks5 + 测试连接 | 正常；填死代理时报 `RhttpConnectionException`，不卡不崩 |
| 连续请求 index 时延 | 见 6.2 |

---

## 7. 后续待办（按性价比排序）

1. **按源 / 按域名分流代理**（最急）
   rhttp 0.15.1 只有 `ProxySettings.proxy/static(condition: http|https|all)`，**做不到域名级分流**。
   现实做法：`AppDio` 层按 `sourceKey` 或域名规则维护多个 adapter/客户端，各自带不同 proxy；
   或给 rhttp 提 PR 支持按 host 规则。前置：源脚本跑在 JS 环境里，需把 `sourceKey` 透传到请求。
2. **DoH / DoT 解析**：目前只有静态 DNS 覆写（`enableDnsOverrides` + `dnsOverrides`），遇到污染无解。
3. **镜像测速结果持久化**：现在每次刷新都并发打 5 个域名；可缓存最佳镜像 1h。
4. **源脚本内的域名替换入口**：如拷贝漫画把 `www.copy20.com` 写死在 JS 里，需要源级 `dnsOverride`/域名映射能力。
5. `_getOverrides()` 里的 `if (!appdata.settings['enableDnsOverrides'] == true)` 可读性极差（语义正确但易误改），建议写成 `!= true`。
6. `MyLogInterceptor.onRequest` 里硬编码 15s 超时，与 rhttp client 的 `TimeoutSettings` 重复，建议收到一处。
7. 代理“测试连接”期间会把临时 proxy 写进全局 settings（其它并发请求可能短暂走该代理），可改为构造独立 client 测试。
8. `logs.txt` 冷启动截断：考虑改用追加模式并做轮转，便于排障。
9. headless 模式（`--headless webdav/updatescript/updatesubscribe`）可用来做 CI 化的连通性自检。

---

## 8. 开发约定

* 语言：回复/文档用中文，代码标识符、命令、日志保持原文。
* 提交：Conventional Commits（`fix(network): ...` / `perf(network): ...`），正文写清根因与验证。
* **不要**把 `android/key.properties`、`*.jks`、`build/`、`.dart_tool/` 提交进版本库。
* 没有明确要求时**不要 push**、不要 commit 无关文件。
* 改完网络层建议至少跑一次：`flutter analyze <改动文件>` + 真机构建安装 + 上面的验证清单。

---

## 9. 快速自检脚本（复现网络结论）

```bash
# 在手机 root shell 里逐条测
t() { printf '%-45s ' "$1"; curl -sS -m 10 -o /dev/null -w 'code=%{http_code} ip=%{remote_ip}\n' "$1"; }
t "https://cdn.jsdelivr.net/gh/venera-app/venera-configs@main/index.json"
t "https://fastly.jsdelivr.net/gh/venera-app/venera-configs@main/index.json"
t "https://gcore.jsdelivr.net/gh/venera-app/venera-configs@main/index.json"
t "https://raw.githubusercontent.com/venera-app/venera-configs/main/index.json"
```

推入并执行：

```powershell
adb -s 192.168.10.206:42165 push .\nettest.sh /data/local/tmp/nettest.sh
adb -s 192.168.10.206:42165 shell "su -c 'sh /data/local/tmp/nettest.sh'"
```
