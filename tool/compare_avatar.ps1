# 对比两张截图里「浮窗内数字人模型」的位置与宽高比
#
# 用法：powershell -File tool/compare_avatar.ps1 <imgA> <imgB> [标签A] [标签B]
#
# 原理：把图缩到 1/3 加速，再在「浮窗区域」里按
#   与背景色的差异大 + 整体偏暗（头发/衣服是深色）
# 筛出模型像素，求包围盒。
$ImgA = $args[0]
$ImgB = $args[1]
$LabelA = if ($args.Count -gt 2) { $args[2] } else { 'A' }
$LabelB = if ($args.Count -gt 3) { $args[3] } else { 'B' }

Add-Type -AssemblyName System.Drawing

function Get-ModelBox([string]$path) {
  $src = [System.Drawing.Bitmap]::FromFile((Resolve-Path $path))
  $scale = 3
  $w = [int]($src.Width / $scale)
  $h = [int]($src.Height / $scale)
  $bmp = New-Object System.Drawing.Bitmap($w, $h)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.InterpolationMode = 'HighQualityBicubic'
  $g.DrawImage($src, 0, 0, $w, $h)
  $g.Dispose(); $src.Dispose()

  $bg = $bmp.GetPixel(3, 3)
  $x0 = 999999; $y0 = 999999; $x1 = -1; $y1 = -1; $cnt = 0
  for ($y = 0; $y -lt [Math]::Min(460, $h); $y++) {
    for ($x = 0; $x -lt $w; $x++) {
      $p = $bmp.GetPixel($x, $y)
      $dr = [Math]::Abs($p.R - $bg.R)
      $dg = [Math]::Abs($p.G - $bg.G)
      $db = [Math]::Abs($p.B - $bg.B)
      $diff = [Math]::Max($dr, [Math]::Max($dg, $db))
      if ($diff -gt 40 -and ($p.R + $p.G + $p.B) -lt 480) {
        if ($x -lt $x0) { $x0 = $x }
        if ($y -lt $y0) { $y0 = $y }
        if ($x -gt $x1) { $x1 = $x }
        if ($y -gt $y1) { $y1 = $y }
        $cnt++
      }
    }
  }
  $bmp.Dispose()
  if ($cnt -eq 0) { return $null }
  return [pscustomobject]@{
    X0 = $x0; Y0 = $y0; X1 = $x1; Y1 = $y1; Count = $cnt
    W = $x1 - $x0 + 1; H = $y1 - $y0 + 1
    CX = [int](($x0 + $x1) / 2); CY = [int](($y0 + $y1) / 2)
    Scale = $scale
  }
}

$a = Get-ModelBox $ImgA
$b = Get-ModelBox $ImgB

function Show([string]$label, $box) {
  if ($null -eq $box) { Write-Host "$label : 未检测到模型像素"; return }
  Write-Host "$label :"
  Write-Host ("  包围盒   x {0}~{1}   y {2}~{3}   (缩放 1/{4})" -f $box.X0, $box.X1, $box.Y0, $box.Y1, $box.Scale)
  Write-Host ("  尺寸     {0} x {1}" -f $box.W, $box.H)
  Write-Host ("  宽高比   w/h = {0}" -f [Math]::Round($box.W / $box.H, 3))
  Write-Host ("  中心     ({0}, {1})" -f $box.CX, $box.CY)
}

Show $LabelA $a
Show $LabelB $b
if ($null -ne $a -and $null -ne $b) {
  Write-Host ""
  Write-Host "差异 (B 相对 A) :"
  Write-Host ("  高度倍率 {0}" -f [Math]::Round($b.H / $a.H, 3))
  Write-Host ("  宽高比差 {0}" -f [Math]::Round(($b.W / $b.H) - ($a.W / $a.H), 3))
  Write-Host ("  中心 dx  {0}" -f ($b.CX - $a.CX))
  Write-Host ("  中心 dy  {0}" -f ($b.CY - $a.CY))
}
