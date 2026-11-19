# Joolink 探针（dylib 注入版）

针对乔安智联 4.4.79（`com.qiaoan.qiaoanzhilian`）的**只读观测 dylib**。
用来定位「个别设备跳转回放后直接显示当前时间无录像」到底是哪一环断了。

无 Theos、无 deb、无 plist，纯 `probe.m` + clang 编译出一个 dylib，自己注入。

## 产物

`JoolinkProbe.dylib`（arm64，iOS 15.0+，依赖 Foundation / UIKit）

## 编译

GitHub Actions 已配好（`.github/workflows/build.yml`），push 到 `main` 自动编译，
在 Actions 页面下载 `JoolinkProbe-dylib` 产物。

本机编译（macOS）：

```bash
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
clang -isysroot "$SDK" -arch arm64 -miphoneos-version-min=15.0 \
      -dynamiclib -fobjc-arc -fblocks \
      -framework Foundation -framework UIKit \
      probe.m -o JoolinkProbe.dylib
ldid -S JoolinkProbe.dylib
```

## 记录什么

| 前缀 | 内容 | 用途 |
|---|---|---|
| `CH-IN` | Flutter 通道调用：通道名、方法、入参 | 看那台设备走了哪条链路 |
| `CH-OUT` | 同一调用的**返回值** | **最关键**：接口有没有数据 |
| `CH→Dart` | 原生回调 Dart | 错误码、空列表 |
| `NET` | AFNetworking 请求 URL + 字节数 | 原生侧接口 |
| `JB` | 越狱路径查询结果 | 广告 SDK 检测行为 |

启动时会打一行自检：

```
=== JoolinkProbe(dylib) loaded | CH-handler=1 CH-invoke=1 NET=1 JB=1 | log=... ===
```

四个值都是 1 才算四个 hook 点全部挂上。哪个是 0，说明那个类或方法在这个版本里不存在，要换 hook 点。

## 日志位置

App 沙箱内 `Documents/jl_probe.log`。

```bash
ssh root@设备IP
find /var/mobile/Containers/Data/Application -name jl_probe.log 2>/dev/null
scp root@设备IP:"<上面路径>" ./jl_probe.log
```

或开 Console.app 过滤 `com.jl.probe` 实时看。

## 测试步骤

1. 注入 dylib，重启 Joolink
2. **先正常进一次好设备的回放**（留基线）
3. 再进那台失效设备的回放
4. 等 10 秒退出
5. 拉日志对比

## 怎么读结论

看 `CH-OUT`：

```
[12:04:32.115] CH-OUT com.jooan.record-plan.fetch-sd-company :: fetchSDCompany  ret={code=0, list=[]}
```

- `list=[]` → 那台设备根本没有那天录像数据，问题在设备侧/服务端，跟 UI 无关
- `list` 有数据但界面空 → 前端解析问题，才需要动 hook
- `CH-IN` 里完全没有 `record-plan` 相关调用 → 没走到这一步，问题更靠前（设备能力查询/权限）

## 注意

1. 日志上限 20 MB，超了自动清空，不会写满设备。
2. 参数截前 3000 字符，大 JSON 不会撑爆。
3. 纯 runtime hook（`method_setImplementation`），不依赖 ElleKit/Substrate API，注入即生效。
4. 只读，不改任何业务逻辑，可以和路径隐藏 tweak 共存。
5. 如果编译失败，把 Actions 的日志发我。
