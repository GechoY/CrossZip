param(
    [Parameter(Mandatory = $true)][string]$ExtractedPath,
    [string]$Extractor = 'Windows File Explorer (recorded by tester)'
)
$ErrorActionPreference = 'Stop'
$expected = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'expected.json') -Encoding UTF8 -Raw | ConvertFrom-Json
$root = (Resolve-Path -LiteralPath $ExtractedPath).Path.TrimEnd([char[]]@('\', '/'))
$files = @(Get-ChildItem -LiteralPath $root -File -Recurse -Force)
$actualNames = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($file in $files) {
    $relative = $file.FullName.Substring($root.Length + 1).Replace('\', '/').Normalize([Text.NormalizationForm]::FormC)
    [void]$actualNames.Add($relative)
}
if ($files.Count -ne $expected.files.Count) { throw "文件数量不一致：实际 $($files.Count)，预期 $($expected.files.Count)" }
foreach ($item in $expected.files) {
    if (-not $actualNames.Contains($item.path)) { throw "文件名或大小写不符：$($item.path)" }
    $path = Join-Path $root ($item.path.Replace('/', '\'))
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "缺少文件：$($item.path)" }
    if ((Get-Item -LiteralPath $path -Force).Length -ne $item.size) { throw "大小不符：$($item.path)" }
    $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($hash -ne $item.sha256) { throw "SHA-256 不符：$($item.path)" }
}
foreach ($directory in $expected.directories) {
    if (-not (Test-Path -LiteralPath (Join-Path $root ($directory.Replace('/', '\'))) -PathType Container)) {
        throw "缺少目录：$directory"
    }
}
$actualDirectories = @(Get-ChildItem -LiteralPath $root -Directory -Recurse -Force)
if ($actualDirectories.Count -ne $expected.directories.Count) { throw '目录数量不一致，存在遗漏或额外目录。' }
$directoryNames = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($directory in $actualDirectories) {
    [void]$directoryNames.Add($directory.FullName.Substring($root.Length + 1).Replace('\', '/').Normalize([Text.NormalizationForm]::FormC))
}
foreach ($directory in $expected.directories) {
    if (-not $directoryNames.Contains($directory)) { throw "目录名或大小写不符：$directory" }
}
$os = Get-CimInstance Win32_OperatingSystem
$result = [ordered]@{
    status = 'passed'; os = $os.Caption; version = $os.Version; build = $os.BuildNumber
    extractor_reported_by_tester = $Extractor; checked_at = (Get-Date).ToString('o')
    extracted_path = $root; file_count = $files.Count; directory_count = $actualDirectories.Count
    checks = 'Relative paths, file/directory counts, lengths and SHA-256'
}
$result | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $PSScriptRoot 'windows-result.json') -Encoding UTF8
Write-Host '校验通过：文件名、文件数量、空目录、大小和 SHA-256 一致。' -ForegroundColor Green
Write-Host '解压工具由测试人员记录；脚本本身不执行资源管理器解压。'
