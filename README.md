# CrossZip

Mac 上的压缩与解压工具，中文界面，支持 Finder 右键操作。文件在本机处理。

[下载 CrossZip](https://github.com/GechoY/CrossZip/releases/tag/v1.5.2) · Apple 芯片 Mac · macOS 14+

![CrossZip](docs/images/crosszip-light.png)

## 功能

- 拖入多个文件或文件夹一起打包，保留文件名、目录结构和内容。
- 解压前查看包内文件，可选择全部或部分解压。
- 自选保存位置；未选择时，压缩包保存在第一个所选文件或文件夹旁。
- 多选项目打包时增加外层文件夹，已有同名结果自动编号。
- 支持压缩等级选择、预计大小、取消操作和完成后在 Finder 中查看。
- 支持浅色、深色外观，默认跟随系统。

## 支持格式

| 操作 | 格式 |
| --- | --- |
| 压缩 | ZIP / ZIP64、7z、TAR、TAR.GZ、TAR.BZ2、TAR.XZ |
| 解压 | 上述格式，以及 RAR / RAR5、GZ、BZ2、XZ、LZMA、LZIP、Unix compress、CAB、CPIO、ISO、AR |

暂不支持加密包和分卷包。ZIP 支持 Stored、Deflate 压缩方法。
旧 ZIP 文件名显示乱码时，可切换 UTF-8、GB18030 / GBK 或 CP437。

## 安装

下载 DMG，打开后将 **CrossZip.app** 拖到“应用程序”。也可下载 ZIP，解压后移动应用。

应用尚未经过 Apple 公证。首次打开若被系统拦截，可按
[Apple 的说明](https://support.apple.com/zh-cn/102445)，在“系统设置 → 隐私与安全性”中允许打开。

## Finder 右键

首次打开应用后，在 Finder 中选中文件或文件夹，右键选择 **服务 → 使用 CrossZip 压缩**。
系统自带的“压缩”选项也可继续使用。

若菜单中没有显示，可到“系统设置 → 键盘 → 键盘快捷键 → 服务”启用。

## 使用提示

发送给 Windows 用户时，建议选择 ZIP，并使用符合 Windows 命名规则的文件名。
不兼容的名称会提示，打包时仍保留原名。预计大小仅供参考。

列表中的 × 和“全部移除”只移除本次选择，不删除原文件。

## 许可

[MIT License](LICENSE) · [第三方组件声明](THIRD_PARTY_NOTICES.md)
