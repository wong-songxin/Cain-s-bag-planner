# ============================================================
# 打包「可上传的核心代码」
#
# 只带走：
#   metadata.xml
#   main.lua
#   scripts/**/*.lua        （运行时脚本，含 scripts/data/）
#
# 明确排除（只留在仓库里，不进模组目录 / 不进 zip）：
#   prompts/                开发交接文档（step1~5）
#   tests/                  离线测试（stub + 断言 + 穷举参考脚本）
#   tools/                  本打包脚本
#   README.md               开发文档（工坊页面另填）
#   scripts 下的 *.py 等非 .lua 文件（开发期脚本）
#
# 用法：powershell -ExecutionPolicy Bypass -File tools\package.ps1
# 产物：dist\CainsBag\  （可直接挂到 mods\ 下试玩）
#       dist\CainsBag.zip（解压后得到 mods\CainsBag\...）
# ============================================================

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"   # 关掉 Compress-Archive 的进度条刷屏

$root = Split-Path -Parent $PSScriptRoot
$stage = Join-Path $root "dist\CainsBag"
$zip = Join-Path $root "dist\CainsBag.zip"

if (Test-Path -LiteralPath $stage) {
    Remove-Item -LiteralPath $stage -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $stage | Out-Null

foreach ($file in @("metadata.xml", "main.lua")) {
    Copy-Item -LiteralPath (Join-Path $root $file) -Destination $stage
}

$scriptSrc = Join-Path $root "scripts"
$scriptDst = Join-Path $stage "scripts"
Get-ChildItem -LiteralPath $scriptSrc -Recurse -File -Filter "*.lua" | ForEach-Object {
    $relative = $_.FullName.Substring($scriptSrc.Length + 1)
    $target = Join-Path $scriptDst $relative
    $targetDir = Split-Path -Parent $target
    if (-not (Test-Path -LiteralPath $targetDir)) {
        New-Item -ItemType Directory -Force -Path $targetDir | Out-Null
    }
    Copy-Item -LiteralPath $_.FullName -Destination $target
}

# 兜底：核心目录里只允许 .lua + metadata.xml，防止开发文件混进上传包
$leaks = Get-ChildItem -LiteralPath $stage -Recurse -File |
    Where-Object { $_.Extension -ne ".lua" -and $_.Name -ne "metadata.xml" }
if ($leaks) {
    $names = ($leaks | ForEach-Object { $_.FullName.Substring($stage.Length + 1) }) -join ", "
    throw "上传目录里出现了非核心文件：$names"
}

if (Test-Path -LiteralPath $zip) {
    Remove-Item -LiteralPath $zip -Force
}
Compress-Archive -Path $stage -DestinationPath $zip -Force

Write-Host "核心文件已整理到：$stage"
Get-ChildItem -LiteralPath $stage -Recurse -File | Sort-Object FullName | ForEach-Object {
    Write-Host ("  " + $_.FullName.Substring($stage.Length + 1))
}
Write-Host "压缩包：$zip"
