# ================================================================
#  Установка приложений на Geely Cityray (G426) в обход блокировки pm.
#  Кладёт APK из папки apks\ на ГУ через app_process + PackageInstaller API.
#  Требуется: открытый ADB (см. README) и подключение по кабелю/Wi-Fi.
# ================================================================
$ErrorActionPreference = "Continue"
$root   = Split-Path $PSScriptRoot -Parent
$dex    = Join-Path $root "helper\installer.dex"
$apkDir = Join-Path $root "apks"

# --- найти adb ---
$adb = $null
$cmd = Get-Command adb -ErrorAction SilentlyContinue
if ($cmd) { $adb = $cmd.Source }
if (-not $adb) {
  $wg = "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\Google.PlatformTools_Microsoft.Winget.Source_8wekyb3d8bbwe\platform-tools\adb.exe"
  if (Test-Path $wg) { $adb = $wg }
}
if (-not $adb) {
  Write-Host "ADB не найден. Установите его командой:  winget install Google.PlatformTools" -ForegroundColor Red
  Write-Host "Затем закройте и снова откройте это окно." -ForegroundColor Red
  return
}

function Sh([string]$c,[int]$to=300){ $j=Start-Job{param($a,$x) "$x`nexit`n"|& $a shell 2>&1}-ArgumentList $adb,$c; if(Wait-Job $j -Timeout $to){$r=Receive-Job $j}else{$r='__TIMEOUT__';Stop-Job $j}; Remove-Job $j -Force; return ($r|Out-String) }

Write-Host "=== 1. Проверка подключения ===" -ForegroundColor Cyan
& $adb start-server 2>&1 | Out-Null; Start-Sleep 1
if ("$(& $adb get-state 2>&1)" -notmatch '^device') {
  Write-Host "Магнитола не подключена по ADB." -ForegroundColor Red
  Write-Host "Откройте ADB на ГУ (инженерка -> ADB -> Open, код через GeelyTool) и подключите кабель." -ForegroundColor Yellow
  return
}
& $adb devices

if (-not (Test-Path $dex)) { Write-Host "Нет файла helper\installer.dex" -ForegroundColor Red; return }
$apks = Get-ChildItem $apkDir -Filter *.apk -ErrorAction SilentlyContinue
if (-not $apks) { Write-Host "В папке apks\ нет ни одного .apk. Положите туда нужные приложения." -ForegroundColor Yellow; return }

Write-Host "`n=== 2. Заливаю хелпер и приложения ($($apks.Count) шт.) ===" -ForegroundColor Cyan
& $adb push $dex /data/local/tmp/installer.dex 2>&1 | Out-Null
[void](Sh "rm -rf /data/local/tmp/apks; mkdir -p /data/local/tmp/apks")
$onDevice = @()
foreach ($a in $apks) {
  $safe = "/data/local/tmp/apks/" + ($a.Name -replace '[^A-Za-z0-9._-]','_')
  & $adb push "$($a.FullName)" $safe 2>&1 | Out-Null
  $onDevice += $safe
  Write-Host "  + $($a.Name)"
}

Write-Host "`n=== 3. Установка (обход pm) ===" -ForegroundColor Cyan
$run = "CLASSPATH=/data/local/tmp/installer.dex app_process /system/bin Installer " + ($onDevice -join ' ')
Write-Host (Sh $run 600)

Write-Host "=== 4. Что стоит теперь (сторонние) ===" -ForegroundColor Cyan
Write-Host (Sh "pm list packages -3")
Write-Host "`nГотово. Приложения появятся в лаунчере GLauncher/GInputBridge." -ForegroundColor Green
