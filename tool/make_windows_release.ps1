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
#   powershell -ExecutionPolicy Bypass -File tool\make_windows_release.ps1 -Version 1.2.1 -OutDir build
#
# GitHub Actions 用的就是第三种（把 zip 直接落在 build/ 下，与上传路径匹配）。

param(
  [string]$Version = "dev",
  [string]$OutDir  = ""
)

$ErrorActionPreference = "Stop"

$root    = Split-Path -Parent $PSScriptRoot
$src     = Join-Path $root "build\windows\x64\runner\Release"
$staging = Join-Path $root "build\windows\_staging"

if ($OutDir -ne "") {
  $outDir = Join-Path $root $OutDir
} else {
  $outDir = Join-Path $root "build\windows"
}

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

# zip 内的目录名固定不带版本：用户解压后得到一个稳定名字，
# 版本号放在 zip 文件名上就够了。
$folderName = "call-assistant-windows-x64"
$zipName    = "call-assistant-$Version-windows-x64.zip"
if (-not (Test-Path $outDir)) {
  New-Item -ItemType Directory -Path $outDir -Force | Out-Null
}
$zip = Join-Path $outDir $zipName

# 先把 Release 内容搬到 staging\<folderName>\ 下，再压缩 staging。
# 这样 zip 里的第一层就是 <folderName>\。
$target = Join-Path $staging $folderName
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

# 压缩：优先 7z。资源里模型文件名/目录名带中文，Compress-Archive 在
# 某些环境下会乱码，7z 更稳；没有 7z 时退回 Compress-Archive。
$sevenZip = @(
  "C:\Program Files\7-Zip\7z.exe",
  "C:\Program Files (x86)\7-Zip\7z.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1

# 在 staging 目录里执行，这样 "*" 展开成 <folderName>，
# zip 内的路径就是 <folderName>\...（而不是绝对路径）
Push-Location $staging
try {
  if ($sevenZip) {
    Write-Host "压缩（7z） -> $zip"
    & $sevenZip a -tzip $zip "*" | Out-Host
  } else {
    Write-Host "压缩（Compress-Archive） -> $zip"
    Compress-Archive -Path "*" -DestinationPath $zip -CompressionLevel Optimal
  }
} finally {
  Pop-Location
}

if (-not (Test-Path $zip)) { throw "打包失败：$zip" }

Remove-Item -Recurse -Force $staging

$size = [math]::Round((Get-Item $zip).Length / 1MB, 1)
Write-Host ""
Write-Host "完成：$zip （$size MB）"
Write-Host "解压后结构：$folderName\call_assistant.exe"
