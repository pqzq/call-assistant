# 打包 Windows release 成 zip。
#
# 目标结构（解压后只有一层）：
#   call-assistant-windows-x64\call_assistant.exe
#
# Flutter 的产物在 build\windows\x64\runner\Release 下，直接压缩那一层会把
# exe 和一堆 dll 平铺在 zip 根目录，解压后文件散一地；手动打包又容易多套几层。
# 这里统一搬到 staging 的子目录里再压缩，保证 zip 内第一层就是发行目录。
#
# 用法：
#   powershell -ExecutionPolicy Bypass -File tool\make_windows_release.ps1
#   powershell -ExecutionPolicy Bypass -File tool\make_windows_release.ps1 -Version 1.2.1

param(
  [string]$Version = "dev"
)

$ErrorActionPreference = "Stop"

$root    = Split-Path -Parent $PSScriptRoot
$src     = Join-Path $root "build\windows\x64\runner\Release"
$staging = Join-Path $root "build\windows\_staging"
$outDir  = Join-Path $root "build\windows"

if (-not (Test-Path $src)) {
  Write-Host "找不到产物目录：$src"
  Write-Host "请先执行： flutter build windows --release"
  exit 1
}

$exe = Join-Path $src "call_assistant.exe"
if (-not (Test-Path $exe)) {
  Write-Host "产物里没有 call_assistant.exe，目录内容如下："
  Get-ChildItem $src | ForEach-Object { Write-Host "  $($_.Name)" }
  exit 1
}

if ($Version -eq "dev") {
  $name = "call-assistant-windows-x64"
} else {
  $name = "call-assistant-windows-x64-$Version"
}
$zip = Join-Path $outDir "$name.zip"

# 先把 Release 内容搬到 staging\<name>\ 下，再压缩 staging。
# 这样 zip 里的第一层就是 <name>\。
$target = Join-Path $staging $name
if (Test-Path $staging) { Remove-Item -Recurse -Force $staging }
New-Item -ItemType Directory -Path $target -Force | Out-Null

Write-Host "复制产物 -> $target"

# 排除上次运行残留的 userdata：里面有用户数据、导入的模型和日志，
# 打进发行包既占体积又可能带上私人数据。
# 注意：要先过滤再 Copy —— 在 ForEach-Object 里用 return 跳过某一项
# 会直接退出整个脚本，而不是继续下一项。
$skipName = "userdata"
$items = @(Get-ChildItem $src -Force | Where-Object { $_.Name -ne $skipName })
foreach ($item in $items) {
  Copy-Item -Path $item.FullName -Destination $target -Recurse -Force
}
if (Test-Path (Join-Path $src $skipName)) {
  Write-Host "  已排除 $skipName （运行时生成，不进发行包）"
}

if (Test-Path $zip) { Remove-Item -Force $zip }
Write-Host "压缩 -> $zip"
Compress-Archive -Path (Join-Path $staging "*") -DestinationPath $zip -CompressionLevel Optimal

Remove-Item -Recurse -Force $staging

$size = [math]::Round((Get-Item $zip).Length / 1MB, 1)
Write-Host ""
Write-Host "完成：$zip （$size MB）"
Write-Host "解压后结构：$name\call_assistant.exe"
