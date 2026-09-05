# ZebTrace 使用指南

ZebTrace 是一个极简 macOS 菜单栏录音工具。当前版本为 **v0.2.0 预览版**，手动控制开始与暂停，分别保存系统声音和麦克风音轨。

## 下载安装

运行只需要 **macOS 14.2 或更高版本**，不需要安装 Xcode、Swift、Homebrew 或 FFmpeg。

1. **[下载 ZebTrace v0.2.0（Universal DMG）](https://github.com/cutelizebin/zebtrace/releases/download/v0.2.0/ZebTrace-0.2.0-universal-preview-unnotarized.dmg)**。同一个安装包同时包含 Apple Silicon 和 Intel 原生版本；ZIP、校验和与版本说明见 [v0.2.0 发布页](https://github.com/cutelizebin/zebtrace/releases/tag/v0.2.0)。
2. 打开 DMG，把 **ZebTrace.app** 拖入 **Applications（应用程序）**。
3. 从“应用程序”打开 ZebTrace，在顶部菜单栏找到 **Z** 图标。

当前提供未公证预览版。如果首次打开被 macOS 阻止，并且你确认下载来源可信，先尝试打开一次，然后到 **系统设置 → 隐私与安全性 → 仍要打开**，再次确认打开。受管理的 Mac 可能不允许手动放行。详见 [Apple 官方说明](https://support.apple.com/en-us/102445)。后续签名、公证版本会简化首次打开流程。

后续版本可在 [全部发布版本](https://github.com/cutelizebin/zebtrace/releases) 查看。

## 语言

默认 **语言 → 跟随系统**：按 macOS 首选语言顺序匹配中文或英文；中文的地区/书写变体使用简体中文，均不匹配时回退到英文。

也可选择 **简体中文** 或 **English**，菜单和状态立即切换并记住选择，录音可以继续。系统权限弹窗及目录选择器的标准按钮遵循 macOS 自身的应用/系统语言规则；系统语言更改后可能需要重启应用。

## 开始录音

1. 在 macOS 顶部菜单栏找到 ZebTrace 图标。
2. 点击「开始记录」，并按系统提示允许麦克风与系统音频访问。
3. 播放一段声音并对麦克风说话，确认菜单中两路都显示「有声音」。首次建议使用 Mac 内置麦克风和耳机输出。
4. 点击「暂停并保存」，随后点击「打开最近记录」，回放系统声和麦克风两路文件。「打开所有记录」可查看当前保存位置下的会话。

暂停会结束当前会话，再次开始会新建会话。关闭应用后重新打开也不会自动录制。录音只保存在本机，首版不做转写。

默认保存到 `~/Downloads/ZebTrace`。菜单显示当前保存位置，点击「选择保存位置…」可通过系统目录选择器更改，重启后仍会记住。录制期间不能更改；暂停后切换，下次录制使用新位置。如果自选目录被删除或磁盘离线，应用会报错要求重新选择，不会偷偷改存到其他地方。启动时只检查当前保存目录中的未完成会话。

旧版 MyContext 的自定义保存位置与分段设置会一次性迁移，已有 ZebTrace 设置不会被覆盖。这只迁移设置，应用不会自动搬迁或删除录音。应用标识已更换为 `org.zebtrace.app`，首次录制需要为 ZebTrace 重新授予系统权限。

默认每 10 分钟分段，可从「分段时长」子菜单选择 1、5、10、30、60 分钟；设置会记住，录制期间禁用，暂停修改后在下次录制生效。音频边录边写，不会把整段 10 分钟的 PCM 音频留在内存里；点击「暂停并保存」会封存当前文件，无需等满 10 分钟。分段越长，崩溃时尚未封存的末段可能损失的音频也越多。

系统没有播放声音时，菜单可能显示「等待声音…」，这不会自动停止录制。系统音频权限被拒绝时也可能只有静音，因此需要实际播放声音并回放文件验证。麦克风持续 12 秒没有数据时会自动暂停。蓝牙麦克风启用时可能切换通话模式（HFP），这类格式切换尚未完成真机验证，暂不承诺 AirPods 全兼容。

## 从源码构建（开发者）

需要 Xcode 15.1+ 或配套的 Swift 5.9+ / macOS 14.2+ SDK。获取源码后执行：

```sh
git clone https://github.com/cutelizebin/zebtrace.git
cd zebtrace
make run        # 构建并启动本地应用
make check      # 自动测试与应用检查
make package    # 生成 Universal 预览 DMG、ZIP 和校验和
```

如需将源码构建的版本安装到用户应用目录，先退出应用，再执行 `make install`，然后打开 `~/Applications/ZebTrace.app`。普通用户直接下载安装包即可。

[返回项目说明](../README.md) · [架构说明](architecture.md) · [隐私与安全](../SECURITY.md) · [发行说明](distribution.md)
