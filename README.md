# Joolink 探针（Qiaoan 11.19）

针对乔安智联 4.4.79（`com.qiaoan.qiaoanzhilian`）的**只读观测 tweak**。
用来定位「个别设备跳转回放后直接显示当前时间无录像」到底是哪一环断了。

不改任何业务逻辑，只记录三件事。

## 记录什么

| 类别 | 内容 | 用来判断 |
|---|---|---|
| `CH-IN` / `CH-OUT` | Flutter 通道调用：通道名、方法名、入参、返回 | 那台设备走了哪条链路（`fetch-sd-company` 有没有被调用、返回什么） |
| `CH→Dart` | 原生回调给 Dart 的方法 | 错误码、空列表、超时 |
| `NET` | AFNetworking 请求的 URL 与字节数 | 原生侧接口有没有数据 |
| `JB` | 越狱路径查询与结果 | 广告 SDK 查了什么、检测是否生效（配合路径隐藏 tweak 用） |

日志格式：

```
[12:04:31.882] CH-IN  com.jooan.record-plan.fetch-sd-company :: fetchSDCompany  args={uid=..., day=...}
[12:04:32.115] CH-OUT com.jooan.record-plan.fetch-sd-company :: fetchSDCompany  ret={code=0, list=[]}
```

**`CH-OUT` 那行是重点**——`list=[]` 说明服务端/设备侧就没有那天的录像数据，问题不在 UI；`list` 有数据但界面空，才是前端解析问题。

## 日志位置

App 沙箱内 `Documents/jl_probe.log`。

取回方法（设备已越狱 + OpenSSH）：

```bash
ssh root@设备IP
find /var/mobile/Containers/Data/Application -name jl_probe.log 2>/dev/null
```

找到路径后直接拉：

```bash
scp root@设备IP:"<上面找到的路径>" ./jl_probe.log
```

也可以开 Console.app，过滤子系统 `com.jl.probe` 实时看。

## 测试步骤

1. 装上 deb，`killall Joolink` 重启 app
2. 正常进一次回放（让日志有个基线）
3. 切到**那台失效的设备**，点进回放页
4. 等 10 秒，退出
5. 拉日志

日志会自动按时间排序，对比两次操作的 `CH-IN/CH-OUT` 差异就能看出问题。

## 编译

本仓库已配 GitHub Actions（`.github/workflows/build.yml`），push 到 `main` 自动编译，
在 Actions 页面下载 `tweak-deb` 产物。

本地编译（macOS + Theos）：

```bash
export THEOS=~/theos
make package
```

产物：`packages/com.joolink.probe_1.0_iphoneos-arm64.deb`

## 安装

```bash
scp com.joolink.probe_1.0_iphoneos-arm64.deb root@设备IP:/var/mobile/
ssh root@设备IP
/var/jb/usr/bin/dpkg -i /var/mobile/com.joolink.probe_1.0_iphoneos-arm64.deb
killall Joolink
```

## 卸载

```bash
/var/jb/usr/bin/dpkg -r com.joolink.probe
killall Joolink
```

## 注意

1. 日志上限 20 MB，超了自动清空重写，不会把设备写满。
2. 这个 tweak 只观测，**不做任何修改**，可以和安全地跟路径隐藏 tweak 同时装。
3. 参数只截取前 3000 字符，避免大 JSON 撑爆日志。
4. 如果 `CH-IN` 完全看不到 `record-plan` 相关调用，说明那台设备根本没走到 SD 录像计划这一步——问题更靠前（设备能力查询或权限），把日志发我，我接着往下查。
