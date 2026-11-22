# 构建和发布

## 本地构建

依赖 macOS 和 Xcode Command Line Tools。以下命令运行测试并构建 Universal 2 App 或磁盘映像。

```bash
./scripts/test.sh
./scripts/build.sh universal
./scripts/package.sh
```

`build.sh` 可指定 `arm64` 或 `x86_64`，也可把第二个参数设为不存在的 `.app` 目标路径。`package.sh` 可指定产物目录，默认使用 `dist/`。DMG 包含 App、Applications 快捷入口和快速开始文件。SHA-256 文件和 DMG 放在一起，下载者可运行 `shasum -a 256 -c 文件名.dmg.sha256`。

未指定签名身份时生成 `local-test.dmg`。适合下载后自行校验的内测和从源码构建。公开分发优先使用经过公证的版本。 [Apple 分发指南](https://developer.apple.com/documentation/security/packaging-mac-software-for-distribution)

## Developer ID 签名和公证

在维护者的 Mac 上配置有效的 **Developer ID Application** 签名身份和 Xcode 的 `notarytool` 工具。用 `security find-identity -v -p codesigning` 查看本机身份。将公证凭据保存到本机钥匙串，构建仅传递钥匙串配置名称。 [Apple 公证指南](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)

```bash
SIGN_IDENTITY='Developer ID Application: YOUR NAME (TEAMID)' \
NOTARY_PROFILE='qr888-notary' \
./scripts/package.sh
```

脚本会签名 App 和 DMG，上传 DMG 完成公证，再附加并验证公证票据。成功后生成 `notarized.dmg` 和校验文件。发布前用 `spctl --assess --type open --context context:primary-signature -v <文件.dmg>` 检查发布件，并拿一台未安装过本 App 的 Mac 做首次安装验证。

## 本地验收

- 运行所有源代码测试，检查通用 App 同时含 `arm64` 和 `x86_64` 切片。
- 验证官方驱动已安装与未安装时的入口。验证创建队列、复用原队列和同名冲突处理。
- 从不同来源提交样张，核对尺寸、页数和最后一页。先验证取消，再用实物做少量试打。
- 从菜单查看独立的待预览任务。检查系统队列保留用户原先选定的默认打印机。
- 只上传本仓库的源码和本项目生成的发布资产。核对 ZIP 和 DMG 文件清单，确认没有厂商驱动、实机日志、客户标签或个人路径。

## 开发时的隔离预览

`--preview-test-dir <目录>` 启动离线预览实例，监听 `127.0.0.1:19152/qr888`，确认时也只在指定目录写入 `.tspl`，无需蓝牙或真实打印机。`--setup-test-dir <目录>` 还启用设置和蓝牙选择菜单，创建 `QR888_RELEASE_TEST` 测试队列。此模式的打印任务同样只写入文件。测试结束后从系统设置移除测试队列，并退出该实例。
