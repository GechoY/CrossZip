CrossZip Windows 实机验收

当前状态：待 Windows 10 / 11 实机运行。本目录不是已经通过 Windows 验收的证明。

1. 将整个 WindowsAcceptance 文件夹复制到 Windows。
2. 在文件资源管理器中，右键 CrossZip-WindowsTest.zip，选择“全部解压”。
   建议使用短目录，例如 C:\Extract\CrossZipTest。
3. 确认该目录下直接包含“跨系统资料”文件夹。不要把“跨系统资料”本身作为下面命令的参数。
4. 在 PowerShell 中进入本文件夹，运行：

   powershell -NoProfile -ExecutionPolicy Bypass -File .\Verify-Windows.ps1 -ExtractedPath 'C:\Extract\CrossZipTest'

   ExecutionPolicy Bypass 仅作用于本次进程，不修改系统持久设置。
   脚本校验文件名、数量、目录、文件大小和 SHA-256；通过后生成 windows-result.json。
5. 在资源管理器中将“跨系统资料”重新压缩为 ZIP，复制回 Mac，用 CrossZip 预览、解压。
   在 Mac 上运行源代码目录的 scripts/verify_return.py，对照 expected.json 检查反向传输结果。

请记录 Windows 版本、构建号、使用的解压工具和 windows-result.json。
Windows 10 与 Windows 11 应分别留存结果；一种系统的结果不能替代另一种。
