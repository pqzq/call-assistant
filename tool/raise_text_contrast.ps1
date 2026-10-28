# 把「文字」用的浅色统一提到 black54（图标 / 边框 / 分割线不动）
#
# 背景：项目里 black26 / black38 / black45 共 65 处，多数是 11~13px 的说明文字。
# 汉字笔画密，浅灰 + 小字号在白底上看着就是「糊」—— 这不是渲染问题，是对比度不足。
#
# 判断规则（保守）：
#   1. 该行含 TextStyle            -> 文字，替换
#   2. 该行是单独的 color: ... 行  -> 往上找 6 行，遇到 TextStyle( 就算文字
#   3. 其余（Icon / BorderSide / Divider / BoxDecoration）-> 保持原色
#
# 注意：本文件必须存为 UTF-8 with BOM（PowerShell 5.1 读无 BOM 的 UTF-8 会按 ANSI 解析）

$root = Join-Path (Split-Path -Parent $PSScriptRoot) 'lib'
if (-not (Test-Path $root)) { throw "找不到 lib 目录: $root" }

$pattern = 'Colors\.black(26|38|45)'
$files = Get-ChildItem $root -Recurse -Filter '*.dart'
$total = 0
$report = @()

foreach ($f in $files) {
  $lines = Get-Content $f.FullName -Encoding utf8
  $changed = 0

  for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -notmatch $pattern) { continue }

    $inTextStyle = $false
    if ($lines[$i] -match 'TextStyle') {
      $inTextStyle = $true
    }
    else {
      # 单独一行的 color: Colors.blackXX —— 往上找最近的 TextStyle(
      for ($j = $i - 1; $j -ge [Math]::Max(0, $i - 6); $j--) {
        if ($lines[$j] -match 'TextStyle\(') { $inTextStyle = $true; break }
        # 遇到明显结束的语句就停，避免跨到上一个块的 TextStyle
        if ($lines[$j] -match '^\s*\)\s*,?\s*$') { break }
      }
    }

    if ($inTextStyle) {
      $lines[$i] = $lines[$i] -replace $pattern, 'Colors.black54'
      $changed++
    }
  }

  if ($changed -gt 0) {
    [System.IO.File]::WriteAllLines($f.FullName, $lines, (New-Object System.Text.UTF8Encoding($false)))
    $report += ('{0,-40} {1}' -f $f.Name, $changed)
    $total += $changed
  }
}

$report | ForEach-Object { Write-Host "  $_" }
Write-Host "共替换 $total 处（文字）"
