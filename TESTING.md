# 测试说明

运行环境：Apple 芯片 Mac，macOS 14+，Swift 5.9+，Python 3.9+。
首次从源码运行前，先执行 `bash scripts/build_native.sh`。

## 一次运行

```sh
bash scripts/check.sh
```

该脚本依次运行 Swift 用例、Release 构建、独立 ZIP 与多格式交叉验证、返回清单校验脚本测试，
并生成两个 Windows 验收场景。Python 脚本和独立系统工具仅用于开发测试，应用运行不依赖它们。

## 大型边界测试

```sh
CROSSZIP_LARGE_TESTS=1 swift test
```

包含 4 GiB + 17 字节实际往返及 SHA-256 比较，以及 65,536 个文件的 ZIP64。
会增加运行时间和磁盘使用量，建议预留至少 10 GB 空间。默认常规测试明确跳过这两项。

## 覆盖内容

- 六种输出格式往返，文件名、空目录、隐藏文件、零字节内容、中文、emoji、原始换行和二进制 SHA-256。
- 普通、失效、循环及外部符号链接；TAR 硬链接链和只选别名的解压。
- Stored / Deflate、ZIP64、流式描述符、旧名称编码、Unicode Path 扩展。
- 格式识别，包括以 `PK` 开头的 TAR 文件名，以及空 ZIP / ZIP64。
- 重复条目、结构冲突、越界路径、目录截断、重叠范围、CRC 和大小错误。
- 取消、源文件变化、不可读取对象、权限和模拟空间不足，确认不发布半成品。
- 默认或自选保存目录、外层目录、移除及重新添加、同名编号、外观、后台估算和退出清理。
- Finder 服务的选择接收、忙碌和模态窗口保护、原系统关联保留。

独立 Python `zipfile`、zlib、tarfile、gzip、bz2、lzma 和 macOS 系统工具用于交叉验证。
多格式报告为 `test-artifacts/multiformat-interop-report.json`，ZIP 报告由 `test_interop.py --report` 指定。
这些本机生成文件不随源码发布。

## Windows

```sh
python3 scripts/prepare_windows_test.py --cli dist/crosszip-cli
python3 scripts/prepare_windows_test.py --cli dist/crosszip-cli --multiple
```

将 `dist/WindowsAcceptance/` 发送到 Windows，按其 README 用资源管理器解压，再运行
`Verify-Windows.ps1` 比较路径、文件与目录数量、长度和 SHA-256，保存 `windows-result.json`。
反向流程用 Windows 创建 ZIP，发回 Mac 后以 `scripts/verify_return.py` 比较原始清单。

GitHub Actions 另配置 Windows Server 2025 上的 PowerShell `Expand-Archive` 和相同 SHA-256 检查。
这只能证明对应 PowerShell 环境的行为；不能替代 Windows 10 / 11 资源管理器或反向传输的实机验收。
只有拿到具体运行结果后，才能把对应环境标记为已验证。

## 发布包

```sh
bash scripts/package_release.sh
cd dist/releases/v1.5.2
shasum -a 256 -c SHA256SUMS
```

还应检查 ZIP 解包后和 DMG 挂载后的 `codesign --verify --strict`、版本、架构和许可证。
本地 ad-hoc 签名验证通过，不表示通过 Apple 公证，也不代表已经在 macOS 14 实机运行。

## 自动检查

`.github/workflows/ci.yml` 使用 Apple 芯片 macOS 15 runner，从干净源码构建并执行大型测试，
再上传应用包、Windows 验收材料和报告。Windows job 下载验收包执行独立解压校验。
GitHub Actions 操作固定到已核对的官方提交。远程通过状态以本仓库 Actions 记录为准。
