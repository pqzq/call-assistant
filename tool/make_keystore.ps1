<#
.SYNOPSIS
    生成 Android 正式签名密钥，并输出 GitHub Actions 需要的 Secret 值。

.DESCRIPTION
    产物：
      android/app/upload-keystore.jks   签名密钥（已被 .gitignore 忽略，不会提交）
      android/key.properties            签名配置（已被 .gitignore 忽略，不会提交）
    终端会打印 4 个 GitHub Secret 的值，粘贴到
    仓库 Settings -> Secrets and variables -> Actions -> New repository secret 即可。

.EXAMPLE
    pwsh -File tool/make_keystore.ps1
    pwsh -File tool/make_keystore.ps1 -Alias mykey
#>
[CmdletBinding()]
param(
    [string]$Alias = 'upload',
    [string]$Keytool = ''
)

$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$jksPath = Join-Path $projectRoot 'android\app\upload-keystore.jks'
$propsPath = Join-Path $projectRoot 'android\key.properties'

# 找 keytool：优先用 JAVA_HOME，其次用 PATH 里的 keytool
if (-not $Keytool) {
    if ($env:JAVA_HOME -and (Test-Path (Join-Path $env:JAVA_HOME 'bin\keytool.exe'))) {
        $Keytool = Join-Path $env:JAVA_HOME 'bin\keytool.exe'
    } else {
        $cmd = Get-Command keytool -ErrorAction SilentlyContinue
        if (-not $cmd) { throw '找不到 keytool，请先安装 JDK 17+ 或用 -Keytool 指定路径' }
        $Keytool = $cmd.Source
    }
}

# 生成随机密码（仅字母数字，避免 key.properties / Gradle 转义问题）
function New-RandomPassword {
    $chars = (48..57) + (65..90) + (97..122)
    return -join (1..24 | ForEach-Object { $chars | Get-Random })
}

$storePassword = New-RandomPassword
$keyPassword = New-RandomPassword

if (Test-Path $jksPath) {
    Write-Host "已存在密钥文件，将被覆盖: $jksPath" -ForegroundColor Yellow
    Remove-Item $jksPath -Force
}

Write-Host '生成签名密钥...' -ForegroundColor Cyan
& $Keytool -genkeypair -v `
    -keystore $jksPath `
    -storetype JKS `
    -keyalg RSA `
    -keysize 2048 `
    -validity 10000 `
    -alias $Alias `
    -storepass $storePassword `
    -keypass $keyPassword `
    -dname 'CN=call-assistant, OU=dev, O=call-assistant, L=Shanghai, ST=Shanghai, C=CN' | Out-Null

if ($LASTEXITCODE -ne 0) { throw 'keytool 生成密钥失败' }

@"
storePassword=$storePassword
keyPassword=$keyPassword
keyAlias=$Alias
storeFile=upload-keystore.jks
"@ | Set-Content -Path $propsPath -Encoding utf8

$base64 = [System.Convert]::ToBase64String([System.IO.File]::ReadAllBytes($jksPath))

Write-Host ''
Write-Host '========== GitHub Secrets ==========' -ForegroundColor Green
Write-Host '仓库 Settings -> Secrets and variables -> Actions -> New repository secret' -ForegroundColor DarkGray
Write-Host ''
Write-Host 'KEYSTORE_BASE64  = ' -NoNewline
Write-Host $base64 -ForegroundColor Yellow
Write-Host 'KEYSTORE_PASSWORD = ' -NoNewline
Write-Host $storePassword -ForegroundColor Yellow
Write-Host 'KEY_ALIAS         = ' -NoNewline
Write-Host $Alias -ForegroundColor Yellow
Write-Host 'KEY_PASSWORD      = ' -NoNewline
Write-Host $keyPassword -ForegroundColor Yellow
Write-Host ''
Write-Host "密钥文件: $jksPath" -ForegroundColor DarkGray
Write-Host "签名配置: $propsPath" -ForegroundColor DarkGray
Write-Host '（两者都已被 .gitignore 忽略，不会被提交）' -ForegroundColor DarkGray
Write-Host '备份好密钥！一旦丢失，已发布应用的更新将无法覆盖安装。' -ForegroundColor Red
