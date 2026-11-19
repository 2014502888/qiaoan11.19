# Joolink 探针 v2（dylib / TrollFools 注入）

针对乔安智联 4.4.79（`com.qiaoan.qiaoanzhilian`）的只读观测 dylib。
用于定位「个别设备跳转回放后直接显示当前时间无录像」走的是哪条链路、接口返回了什么。

**骨架照搬你 v1.32（乔安智联SD直达回放）那套已验证的做法**，不是新写法。

## v2 相对 v1 改了什么（v1 注入闪退的根因）

| 项 | v1（崩） | v2（本版） |
|---|---|---|
| 系统类 hook | hook 了 `NSFileManager fileExistsAtPath:` | **完全不碰系统类** |
| 日志 | ObjC 文件 API + 路径判断 | 纯 C `fopen/fwrite/stat`，pthread 锁 |
| 安装时机 | constructor 直接装齐 | constructor 先同步试一次，类不在则轮询 0.5s×30 |
| 幂等 | 无 | `cur == newImp` 跳过，防重复注入（同 `JASetImp`） |
| 异常 | 无保护 | 每个入口 `@try/@catch`，constructor 内异常不上抛 |

与 v1.32 完全一致的三点：
1. `JPSetImp(Class, SEL, IMP, IMP*)` —— 先取原实现再 `method_setImplementation`
2. `__attribute__((constructor))` 里只做**轻量检查**（`NSClassFromString`），不做重活
3. 类晚加载时后台线程 `sleep 0.5s` 轮询、回主队列重试，最多 30 次

## 只 hook 两个 Flutter 类 + 一个网络类

| 类 | 方法 | 作用 |
|---|---|---|
| `FlutterMethodChannel` | `setMethodCallHandler:` | Dart → 原生：拿到方法名、入参，并包一层 result 拿返回值 |
| `FlutterMethodChannel` | `invokeMethod:arguments:` | 原生 → Dart：错误回调、事件推送 |
| `AFHTTPResponseSerializer` | `responseObjectForResponse:data:error:` | 原生网络请求 URL 与响应长度（类不存在则跳过） |

**不再 hook `NSFileManager`**——回放问题和越狱检测无关，那条 hook 只有风险没有收益。

## 编译

GitHub Actions 已配（ubuntu + clang 交叉编译），push 到 `main` 自动出 `JoolinkProbe.dylib`。

本机：

```bash
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
clang -isysroot "$SDK" -arch arm64 -miphoneos-version-min=15.0 \
      -dynamiclib -fobjc-arc -fblocks \
      -framework Foundation -framework UIKit \
      probe.m -o JoolinkProbe.dylib
ldid -S JoolinkProbe.dylib
```

## 注入（TrollFools）

直接拖 `JoolinkProbe.dylib` 进 TrollFools，选 `Joolink` 注入即可。
TrollFools 会自己重签，不需要额外的 plist 或 Bundle 配置。

## 验证顺序

1. 注入 → 重启 app
2. 看日志第一行：

```
=== JoolinkProbe v2 loaded | log=... ===
```

3. 再看是否出现：

```
=== hooks ready | chan=1 net=1 ===
```

`chan=1` 是关键。如果是 0，说明 `FlutterMethodChannel` 没找到（Flutter framework 未加载或类名变了），日志里会有：

```
=== poll finished | chan=0 net=? tries=30 ===
```

有这行就说明轮询 15 秒都没等到，需要换 hook 点，把日志发我。

## 日志位置

`Documents/jl_probe.log`（沙箱内）。

```bash
ssh root@设备IP
find /var/mobile/Containers/Data/Application -name jl_probe.log 2>/dev/null
scp root@设备IP:"<上面路径>" ./jl_probe.log
```

## 测试步骤

1. 先进一台**正常设备**的回放（留基线）
2. 再进那台**失效设备**的回放
3. 等 10 秒退出，拉日志对比

## 怎么读

核心是 `CH-OUT`：

```
CH-OUT com.jooan.record-plan.fetch-sd-company :: fetchSDCompany  ret={code=0, list=[]}
```

- `list=[]` → 设备/服务端就没那天录像，跟 UI 无关
- 有数据但界面空 → 前端解析问题
- 完全没有 `record-plan` 的 `CH-IN` → 没走到这步，问题更靠前

## 注意

1. 日志 20 MB 上限，超了自动重写，不会写满。
2. 参数截前 3000 字符。
3. 只读，不改业务逻辑，可以和安全相关的 tweak 共存。
4. 如果还闪退，把 `CrashReporter` 里 `Joolink*.ips` 的异常类型和崩溃线程栈发我——这次 v2 已经把系统类 hook 全去掉，理论上不会再因为重入 Foundation 崩。
