# ================================================================
#  Geely Cityray (G426) — Помощник
#  Открыть ADB · Поставить приложения · Быстрые фиксы · Гайд
#  Нужен только установленный adb. Формат флешки требует прав админа.
# ================================================================
param([switch]$Test)

# ======================= HKDF / КОД (проверено на RFC 5869) =======================
function HmacSha256([byte[]]$key,[byte[]]$msg){ $h=New-Object System.Security.Cryptography.HMACSHA256; $h.Key=$key; return $h.ComputeHash($msg) }
function HkdfExtract([byte[]]$salt,[byte[]]$ikm){ return HmacSha256 $salt $ikm }
function HkdfExpand([byte[]]$prk,[byte[]]$info,[int]$len){
  $t=@(); $okm=@(); $n=[math]::Floor(($len+31)/32)
  for($i=0;$i -lt $n;$i++){ $inp=@(); $inp+=$t; $inp+=$info; $inp+=[byte]($i+1); $t=HmacSha256 $prk ([byte[]]$inp); $okm+=$t }
  return ([byte[]]$okm)[0..($len-1)]
}
function EncodeAlnum([byte[]]$data){ $cs="0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"; -join ($data | ForEach-Object { $cs[($_ -band 0xFF)%62] }) }
function Compute-Code([int[]]$salt,[int[]]$password,[string]$sn){
  $saltB=[byte[]]($salt|ForEach-Object{[byte]($_ -band 0xFF)}); $pwB=[byte[]]($password|ForEach-Object{[byte]($_ -band 0xFF)})
  return EncodeAlnum (HkdfExpand (HkdfExtract $saltB $pwB) ([System.Text.Encoding]::UTF8.GetBytes($sn)) 6)
}
function Get-QRResult([string]$root){
  $res=[ordered]@{ ok=$false; code=$null; sn=$null; msg=$null }
  $logs=Get-ChildItem -Path $root -Directory -Filter "logs_*" -EA SilentlyContinue | Sort-Object Name | Select-Object -Last 1
  if(-not $logs){ $res.msg="На флешке нет папки logs_*. Сначала в машине: Adb Switch Open + вставить флешку, дождаться «Android OK / QNX OK»."; return [pscustomobject]$res }
  $zip=Get-ChildItem -Path $logs.FullName -Filter "bugreport-*.zip" -EA SilentlyContinue | Sort-Object Name | Select-Object -Last 1
  if(-not $zip){ $res.msg="В $($logs.Name) нет bugreport-*.zip — выгрузка не завершилась."; return [pscustomobject]$res }
  try{
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $za=[System.IO.Compression.ZipFile]::OpenRead($zip.FullName)
    try{
      foreach($e in $za.Entries){
        if($e.FullName -notlike "*.txt"){ continue }
        $sr=New-Object System.IO.StreamReader($e.Open()); $c=$sr.ReadToEnd(); $sr.Close()
        $sM=[regex]::Matches($c,'salt\s*=\s*\[(.*?)\]'); $pM=[regex]::Matches($c,'password\s*=\s*\[(.*?)\]'); $nM=[regex]::Matches($c,' sn\s*=\s*([A-Za-z0-9_\-.]+)')
        if($sM.Count -and $pM.Count -and $nM.Count){
          $salt=$sM[$sM.Count-1].Groups[1].Value.Split(',')|ForEach-Object{[int]$_.Trim()}
          $pw=$pM[$pM.Count-1].Groups[1].Value.Split(',')|ForEach-Object{[int]$_.Trim()}
          $sn=$nM[$nM.Count-1].Groups[1].Value.Trim()
          $res.code=Compute-Code $salt $pw $sn; $res.sn=$sn; $res.ok=$true; return [pscustomobject]$res
        }
      }
      $res.msg="В bugreport не найдены поля salt/password/sn."
    } finally { $za.Dispose() }
  } catch { $res.msg="Ошибка чтения архива: $($_.Exception.Message)" }
  return [pscustomobject]$res
}

# ======================= ФЛЕШКА =======================
function Get-FlashVolumes(){ Get-CimInstance Win32_LogicalDisk | Where-Object { $_.DriveType -eq 2 } | Select-Object DeviceID,@{N='FS';E={$_.FileSystem}},VolumeName,@{N='SizeGB';E={[math]::Round($_.Size/1GB,1)}} }
function Get-FlashDisks(){ Get-Disk | Where-Object { $_.BusType -eq 'USB' } }
function Format-FlashFAT32([int]$diskNumber){
  $disk=Get-Disk -Number $diskNumber; $diskMB=[int]($disk.Size/1MB); $partMB=[math]::Min(32000,$diskMB-50)
  $script="select disk $diskNumber`r`nclean`r`ncreate partition primary size=$partMB`r`nformat fs=fat32 quick label=GEELY`r`nassign`r`n"
  $tmp=[System.IO.Path]::GetTempFileName(); $script | Out-File -FilePath $tmp -Encoding ascii
  $out=diskpart /s $tmp 2>&1 | Out-String; Remove-Item $tmp -Force -EA SilentlyContinue; Start-Sleep 2
  $part=Get-Partition -DiskNumber $diskNumber -EA SilentlyContinue | Where-Object DriveLetter | Select-Object -First 1
  if($part){ $drive="$($part.DriveLetter):"; New-Item -ItemType File -Path "$drive\svlog.flag" -Force | Out-Null; return @{ ok=$true; drive=$drive; out=$out } }
  return @{ ok=$false; drive=$null; out=$out }
}
function Clean-OldLogs([string]$root){ $n=0; Get-ChildItem -Path $root -Directory -Filter "logs_*" -EA SilentlyContinue | ForEach-Object { cmd /c rmdir /s /q "`"$($_.FullName)`""; $n++ }; return $n }

# ======================= ADB =======================
function Find-Adb(){
  $c=Get-Command adb -EA SilentlyContinue; if($c){ return $c.Source }
  foreach($p in @("$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe","$env:ProgramFiles\platform-tools\adb.exe","$PSScriptRoot\platform-tools\adb.exe","$PSScriptRoot\adb.exe")){ if(Test-Path $p){ return $p } }
  return $null
}
$script:ADB=Find-Adb
function Adb(){ if(-not $script:ADB){ return "ADB не найден" }; return (& $script:ADB @args 2>&1 | Out-String) }
function Adb-Online(){ if(-not $script:ADB){ return $false }; return ((& $script:ADB devices 2>&1) -join "`n") -match "\bdevice\b" }
function Find-InstallerDex(){ foreach($p in @("$PSScriptRoot\installer.dex","$PSScriptRoot\..\helper\installer.dex","$PSScriptRoot\helper\installer.dex")){ if(Test-Path $p){ return (Resolve-Path $p).Path } }; return $null }
function Sdk-ToAndroid([int]$sdk){ switch($sdk){ 29{"10"} 30{"11"} 31{"12"} 32{"12L"} 33{"13"} 34{"14"} 35{"15"} default{"API $sdk"} } }
function Grant-AllPerms([string]$pkg){
  $d=Adb shell "dumpsys package $pkg"
  $perms=[regex]::Matches($d,'(android\.permission\.[A-Z_]+|[a-z0-9.]+\.permission\.[A-Z_]+)') | ForEach-Object { $_.Value } | Sort-Object -Unique
  foreach($perm in $perms){ [void](Adb shell "pm grant $pkg $perm 2>/dev/null") }
}
# Полный фикс одного приложения: включить если выключено, выдать все права,
# определить несовместимость по версии Android. Возвращает короткий статус.
function Fix-App([string]$pkg,[int]$devSdk){
  $d=Adb shell "dumpsys package $pkg"
  if($d -notmatch [regex]::Escape($pkg)){ return "не установлено" }
  $minSdk=$null; if($d -match 'minSdk=(\d+)'){ $minSdk=[int]$Matches[1] }
  if($minSdk -and $minSdk -gt $devSdk){ return ("НЕ ПОДОЙДЁТ: нужен Android "+(Sdk-ToAndroid $minSdk)+", а тут "+(Sdk-ToAndroid $devSdk)) }
  if((Adb shell "pm list packages -d $pkg") -match [regex]::Escape($pkg)){ [void](Adb shell "pm enable $pkg") }
  Grant-AllPerms $pkg
  return "ок (права выданы)"
}
function Get-OverlayApps(){
  $third=@((Adb shell "pm list packages -3") -split "`n" | ForEach-Object { ($_ -replace 'package:','').Trim() } | Where-Object { $_ })
  $q=Adb shell "cmd appops query-op SYSTEM_ALERT_WINDOW allow 2>/dev/null"
  $qlist=@($q -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -notmatch '^No ' })
  $res=@()
  if($qlist.Count){ foreach($p in $qlist){ if($third -contains $p){ $res+=$p } } }
  else { foreach($p in $third){ if((Adb shell "appops get $p SYSTEM_ALERT_WINDOW 2>/dev/null") -match "SYSTEM_ALERT_WINDOW: allow"){ $res+=$p } } }
  return ($res | Sort-Object -Unique)
}
function WiFi-MakePersistent(){
  [void](Adb shell "svc wifi enable")
  [void](Adb shell "settings put global wifi_on 1")
  [void](Adb shell "settings put global wifi_sleep_policy 2")          # 2 = никогда не спать
  [void](Adb shell "settings put global wifi_scan_always_enabled 1")
  [void](Adb shell "settings put global wifi_wakeup_enabled 1")
  [void](Adb shell "settings put global stay_on_while_plugged_in 7")   # ГУ всегда запитано -> не уходит в сон
}

# ======================= САМОПРОВЕРКА =======================
if($Test){
  $ikm=[byte[]](@(0x0b)*22); $salt=[byte[]](0x00..0x0c); $info=[byte[]](0xf0..0xf9)
  $okm=HkdfExpand (HkdfExtract $salt $ikm) $info 42
  $okmHex=($okm|ForEach-Object{$_.ToString('x2')}) -join ''
  Write-Host ("HKDF self-test: {0}" -f ($okmHex -eq '3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865'))
  Write-Host ("Encoder (01Az07): {0}" -f (EncodeAlnum ([byte[]](0,1,10,61,62,255))))
  Write-Host ("ADB: {0}" -f $script:ADB)
  return
}

# ======================= ПРАВА АДМИНА (для формата флешки) =======================
$admin=([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if(-not $admin){ Start-Process powershell -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""; exit }

# ======================= ИНТЕРФЕЙС =======================
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$accent =[Drawing.Color]::FromArgb(38,74,120)
$accent2=[Drawing.Color]::FromArgb(0,140,90)
$bg     =[Drawing.Color]::FromArgb(245,247,250)

$form=New-Object Windows.Forms.Form
$form.Text="Geely Cityray — Помощник"
$form.Size=New-Object Drawing.Size(600,620)
$form.StartPosition="CenterScreen"
$form.Font=New-Object Drawing.Font("Segoe UI",10)
$form.BackColor=$bg

# шапка
$head=New-Object Windows.Forms.Panel
$head.Dock='Top'; $head.Height=62; $head.BackColor=$accent
$form.Controls.Add($head)
$hl=New-Object Windows.Forms.Label
$hl.Text="Geely Cityray"; $hl.ForeColor=[Drawing.Color]::White; $hl.Location='16,10'; $hl.AutoSize=$true
$hl.Font=New-Object Drawing.Font("Segoe UI Semibold",16,[Drawing.FontStyle]::Bold); $hl.BackColor=[Drawing.Color]::Transparent
$head.Controls.Add($hl)
$hs=New-Object Windows.Forms.Label
$hs.Text="Ставит приложения на заблокированную магнитолу Geely"; $hs.ForeColor=[Drawing.Color]::FromArgb(180,200,228); $hs.Location='18,38'; $hs.AutoSize=$true
$hs.Font=New-Object Drawing.Font("Segoe UI",9); $hs.BackColor=[Drawing.Color]::Transparent
$head.Controls.Add($hs)

# лог снизу
$log=New-Object Windows.Forms.TextBox
$log.Dock='Bottom'; $log.Height=110; $log.Multiline=$true; $log.ScrollBars='Vertical'; $log.ReadOnly=$true
$log.Font=New-Object Drawing.Font("Consolas",9); $log.BackColor=[Drawing.Color]::White
$form.Controls.Add($log)
function Say($t){ $log.AppendText((Get-Date -Format "HH:mm:ss")+"  "+$t+"`r`n") }

$tabs=New-Object Windows.Forms.TabControl
$tabs.Dock='Fill'; $tabs.Padding=New-Object Drawing.Point(14,6)
$form.Controls.Add($tabs)
$tabs.BringToFront()

function New-Tab($title){ $t=New-Object Windows.Forms.TabPage; $t.Text="  $title  "; $t.BackColor=$bg; $t.Padding='16,16,16,16'; $tabs.TabPages.Add($t); return $t }
function Round($ctrl,$r){
  $path=New-Object System.Drawing.Drawing2D.GraphicsPath
  $d=$r*2; $w=$ctrl.Width; $h=$ctrl.Height
  $path.AddArc(0,0,$d,$d,180,90); $path.AddArc($w-$d,0,$d,$d,270,90)
  $path.AddArc($w-$d,$h-$d,$d,$d,0,90); $path.AddArc(0,$h-$d,$d,$d,90,90); $path.CloseAllFigures()
  $ctrl.Region=New-Object System.Drawing.Region($path)
}
function Lighten($c,$amt){ [Drawing.Color]::FromArgb([math]::Min(255,$c.R+$amt),[math]::Min(255,$c.G+$amt),[math]::Min(255,$c.B+$amt)) }
function BtnP($p,$x,$y,$w,$h,$text){
  $b=New-Object Windows.Forms.Button; $b.Location="$x,$y"; $b.Size="$w,$h"; $b.Text=$text
  $b.FlatStyle='Flat'; $b.FlatAppearance.BorderSize=0; $b.BackColor=$accent; $b.ForeColor=[Drawing.Color]::White
  $b.FlatAppearance.MouseOverBackColor=(Lighten $accent 22); $b.FlatAppearance.MouseDownBackColor=(Lighten $accent -15)
  $b.Font=New-Object Drawing.Font("Segoe UI Semibold",11,[Drawing.FontStyle]::Bold); $b.Cursor='Hand'; $b.TextAlign='MiddleCenter'
  $p.Controls.Add($b); Round $b 10; return $b
}
function BtnS($p,$x,$y,$w,$h,$text){
  $b=New-Object Windows.Forms.Button; $b.Location="$x,$y"; $b.Size="$w,$h"; $b.Text=$text
  $b.FlatStyle='Flat'; $b.FlatAppearance.BorderSize=1; $b.FlatAppearance.BorderColor=[Drawing.Color]::FromArgb(205,213,224)
  $b.BackColor=[Drawing.Color]::White; $b.ForeColor=$accent; $b.FlatAppearance.MouseOverBackColor=[Drawing.Color]::FromArgb(238,243,250)
  $b.Font=New-Object Drawing.Font("Segoe UI",10); $b.Cursor='Hand'
  $p.Controls.Add($b); Round $b 9; return $b
}
function Lbl($p,$x,$y,$w,$h,$text){ $l=New-Object Windows.Forms.Label; $l.Location="$x,$y"; $l.Size="$w,$h"; $l.Text=$text; $l.BackColor=[Drawing.Color]::Transparent; $p.Controls.Add($l); return $l }

function Check-Conn(){
  if(-not $script:ADB){ Say "ADB не найден — открой вкладку «Как пользоваться»."; return $false }
  if(Adb-Online){ return $true }
  Say "Нет связи с магнитолой: проверь кабель и что ADB открыт."; return $false
}

# ---------- Вкладка 1: Открыть ADB ----------
$t1=New-Tab "Открыть ADB"
$lblDrive=Lbl $t1 4 6 545 34 "Флешка: нажми «Обновить»"
$btnRefresh=BtnS $t1 4 44 545 30 "Обновить список флешек"
$btnPrep=BtnP $t1 4 82 545 52 "Шаг 1 · Подготовить флешку"
$btnCode=BtnP $t1 4 142 545 52 "Шаг 2 · Показать код"
$btnCode.BackColor=$accent2
$lblCode=Lbl $t1 4 202 545 60 "——————"
$lblCode.TextAlign='MiddleCenter'; $lblCode.Font=New-Object Drawing.Font("Consolas",30,[Drawing.FontStyle]::Bold); $lblCode.ForeColor=$accent2
$btnClean=BtnS $t1 4 270 545 28 "Очистить старые логи с флешки"
$h1=Lbl $t1 4 306 545 80 "Подготовь флешку → вставь в USB машины при открытом Adb Switch → дождись «Android OK / QNX OK» → вынь (QR не закрывай!) → вставь в ноут → «Показать код» → введи 6 символов под QR."
$h1.ForeColor=[Drawing.Color]::Gray

$script:sel=$null
function Refresh(){ $v=@(Get-FlashVolumes); if($v.Count -eq 0){ $lblDrive.Text="Флешка не найдена — вставь USB и нажми «Обновить»"; $script:sel=$null; return }; $script:sel=$v[0]; $lblDrive.Text=("Флешка: {0}  ({1}, {2} ГБ)" -f $v[0].DeviceID,$v[0].FS,$v[0].SizeGB) }
$btnRefresh.Add_Click({ Refresh; Say "Список флешек обновлён." })
$btnPrep.Add_Click({
  $d=@(Get-FlashDisks); if($d.Count -eq 0){ [Windows.Forms.MessageBox]::Show("USB-флешка не найдена.","Нет флешки"); return }
  if($d.Count -gt 1){ [Windows.Forms.MessageBox]::Show("Оставь только одну флешку, чтобы не стереть лишнее.","Внимание"); return }
  $x=$d[0]; if([Windows.Forms.MessageBox]::Show("Диск $($x.Number) ($([math]::Round($x.Size/1GB,1)) ГБ) будет полностью стёрт и отформатирован в FAT32. Продолжить?","Подтверждение",'YesNo','Warning') -ne 'Yes'){ return }
  Say "Форматирую..."; $form.Enabled=$false
  try{ $r=Format-FlashFAT32 $x.Number; if($r.ok){ Say "Готово: $($r.drive), FAT32, svlog.flag записан. Неси в машину."; Refresh } else { Say "Не вышло. diskpart: $($r.out)" } }
  catch { Say "ОШИБКА: $($_.Exception.Message)" } finally { $form.Enabled=$true }
})
$btnCode.Add_Click({
  Refresh; if(-not $script:sel){ Say "Флешка не найдена."; return }
  $r=Get-QRResult "$($script:sel.DeviceID)\"
  if($r.ok){ $lblCode.Text=$r.code; [Windows.Forms.Clipboard]::SetText($r.code); Say "КОД: $($r.code) (скопирован). Вводи под QR, регистр важен." } else { $lblCode.Text="——————"; Say $r.msg }
})
$btnClean.Add_Click({ Refresh; if(-not $script:sel){ Say "Флешка не найдена."; return }; $root="$($script:sel.DeviceID)\"; $n=Clean-OldLogs $root; if(-not (Test-Path "$root\svlog.flag")){ New-Item -ItemType File -Path "$root\svlog.flag" -Force | Out-Null }; Say "Удалено папок логов: $n. svlog.flag на месте." })

# ---------- Вкладка 2: Приложения ----------
$t2=New-Tab "Приложения"
Lbl $t2 4 8 545 40 "Открой ADB (вкладка слева) и подключи ноут к машине кабелем." | ForEach-Object { $_.ForeColor=[Drawing.Color]::Gray }
$btnInstall=BtnP $t2 4 54 545 52 "Установить приложения из папки"
$btnGrant=BtnP $t2 4 116 545 52 "Выдать все разрешения всем приложениям"
$btnGrant.BackColor=$accent2
$h2=Lbl $t2 4 180 545 60 "«Установить» — выбери папку с .apk, поставит всё разом.`r`n«Выдать разрешения» — пройдётся по всем установленным и выдаст всё, что можно."
$h2.ForeColor=[Drawing.Color]::Gray
$btnInstall.Add_Click({
  if(-not (Check-Conn)){ return }
  $dex=Find-InstallerDex; if(-not $dex){ Say "Нет installer.dex рядом с программой."; return }
  $fb=New-Object Windows.Forms.FolderBrowserDialog; $fb.Description="Папка с .apk"; if($fb.ShowDialog() -ne 'OK'){ return }
  $apks=@(Get-ChildItem $fb.SelectedPath -Filter *.apk -Recurse -EA SilentlyContinue); if($apks.Count -eq 0){ Say "В папке нет .apk"; return }
  Say "Заливаю хелпер..."; [void](Adb push $dex /data/local/tmp/installer.dex); $ok=0;$fail=0
  foreach($a in $apks){ Say ("Ставлю "+$a.Name); [void](Adb push $a.FullName /data/local/tmp/_ins.apk); $r=Adb shell "CLASSPATH=/data/local/tmp/installer.dex app_process /system/bin Installer /data/local/tmp/_ins.apk"; if($r -match "OK"){ $ok++ } else { $fail++; Say ("  FAIL: "+$r.Trim()) } }
  Say "ИТОГО: OK=$ok FAIL=$fail"
})
$btnGrant.Add_Click({
  if(-not (Check-Conn)){ return }
  $pkgs=@((Adb shell "pm list packages -3") -split "`n" | ForEach-Object { ($_ -replace 'package:','').Trim() } | Where-Object { $_ })
  Say "Приложений: $($pkgs.Count). Выдаю разрешения..."
  foreach($p in $pkgs){ Grant-AllPerms $p }
  Say "Готово. Подписные разрешения система не отдаёт — это нормально."
})

# ---------- Вкладка 3: Фиксы ----------
$t3=New-Tab "Фиксы"
$btnWifiFix=BtnP $t3 4 8 545 52 "Wi-Fi навсегда (не выключается сам)"
$btnWifiOpen=BtnS $t3 4 68 268 32 "Настройки Wi-Fi"
$btnBtOpen=BtnS $t3 281 68 268 32 "Настройки Bluetooth"
$btnOverlay=BtnP $t3 4 108 545 46 "Убрать окна поверх (кроме модов)"
$btnOverlay.BackColor=[Drawing.Color]::FromArgb(190,90,60)
$btnFixAll=BtnP $t3 4 162 545 46 "Починить все приложения"
$btnFixAll.BackColor=$accent2
Lbl $t3 4 214 545 24 "Или одно приложение — впиши пакет и «Починить»:" | Out-Null
$txtPkg=New-Object Windows.Forms.TextBox; $txtPkg.Location='4,240'; $txtPkg.Size='400,26'; $t3.Controls.Add($txtPkg)
$btnFix=BtnS $t3 410 238 139 30 "Починить"
$h3=Lbl $t3 4 274 545 60 "«Wi-Fi навсегда» — включит Wi-Fi и не даст ему засыпать: подключишься один раз, дальше сам.`r`n«Починить все» — пройдёт по всем приложениям: включит выключенные, выдаст права, а какие не подходят по версии Android — назовёт."
$h3.ForeColor=[Drawing.Color]::Gray

$btnWifiFix.Add_Click({ if(-not (Check-Conn)){ return }; WiFi-MakePersistent; Say "Wi-Fi включён и настроен не засыпать. Теперь: «Открыть настройки Wi-Fi» → подключись к своей точке один раз, дальше сам." })
$btnWifiOpen.Add_Click({ if(Check-Conn){ [void](Adb shell "am start -a android.settings.WIFI_SETTINGS"); Say "Открыл настройки Wi-Fi на экране машины." } })
$btnBtOpen.Add_Click({ if(Check-Conn){ [void](Adb shell "am start -a android.settings.BLUETOOTH_SETTINGS"); Say "Открыл настройки Bluetooth на экране машины." } })
$script:keep=@("com.salat.gsplit","com.salat.gmediahud","com.salat.gbinder","com.salat.glauncherlink","android","com.android.systemui")
$btnOverlay.Add_Click({
  if(-not (Check-Conn)){ return }
  Say "Ищу приложения, которые рисуются поверх..."
  $apps=@(Get-OverlayApps | Where-Object { $script:keep -notcontains $_ })
  if($apps.Count -eq 0){ Say "Лишних наложений не найдено."; return }
  if([Windows.Forms.MessageBox]::Show("Убрать наложение поверх у этих приложений?`n`n"+($apps -join "`n")+"`n`nМоды лаунчера/сплита не тронутся.","Убрать наложения",'YesNo','Question') -ne 'Yes'){ return }
  foreach($p in $apps){ [void](Adb shell "appops set $p SYSTEM_ALERT_WINDOW ignore"); [void](Adb shell "am force-stop $p"); Say ("  снято: "+$p) }
  Say "Готово. Всплывающие окна поверх от них больше не появятся."
})
$btnFixAll.Add_Click({
  if(-not (Check-Conn)){ return }
  $devSdk=[int]((Adb shell "getprop ro.build.version.sdk").Trim())
  $pkgs=@((Adb shell "pm list packages -3") -split "`n" | ForEach-Object { ($_ -replace 'package:','').Trim() } | Where-Object { $_ })
  Say "Чиню все приложения: $($pkgs.Count) шт. (Android ГУ: $(Sdk-ToAndroid $devSdk))..."
  $bad=@()
  foreach($p in $pkgs){ $st=Fix-App $p $devSdk; if($st -like "НЕ ПОДОЙДЁТ*"){ $bad+=("  "+$p+" — "+$st) } }
  Say "Готово: всем выданы права, выключенные включены."
  if($bad.Count){ Say "Эти по версии Android не подойдут (нужна версия постарше):"; $bad | ForEach-Object { Say $_ } }
})
$btnFix.Add_Click({
  if(-not (Check-Conn)){ return }
  $p=$txtPkg.Text.Trim(); if(-not $p){ Say "Впиши имя пакета приложения."; return }
  $devSdk=[int]((Adb shell "getprop ro.build.version.sdk").Trim())
  $launch=Adb shell "cmd package resolve-activity --brief -c android.intent.category.LAUNCHER $p"
  $st=Fix-App $p $devSdk
  Say ("$p — $st")
  if($st -like "ок*" -and ($launch -match "No activity found" -or $launch -notmatch "/")){ Say "  (у приложения нет значка — это фоновый сервис/виджет)" }
  if($st -like "ок*"){ Say "  Если всё равно не стартует — скорее всего нужны сервисы Google (их на ГУ нет)." }
})

# ---------- Вкладка 4: Гайд ----------
$t4=New-Tab "Как пользоваться"
$g=New-Object Windows.Forms.TextBox
$g.Dock='Fill'; $g.Multiline=$true; $g.ScrollBars='Vertical'; $g.ReadOnly=$true; $g.BackColor=[Drawing.Color]::White; $g.Font=New-Object Drawing.Font("Segoe UI",10)
$t4.Controls.Add($g)
$gt=@"
ЧТО ЭТО ЗА ПРОГРАММА (простыми словами)

Это помощник для магнитолы Geely, работает на компьютере с Windows.
На новой прошивке магнитола НЕ даёт ставить приложения — ни навигатор, ни ютуб,
ни что угодно. Эта программа снимает блокировку (законно, прошивку не ломает)
и ставит на магнитолу что хочешь.

Что она умеет — 4 вещи:
  1. Открывает магнитолу для установки (готовит флешку и даёт код).
  2. Ставит приложения пачкой и выдаёт им разрешения (микрофон, GPS и т.д.).
  3. Чинит частые беды: Wi-Fi отваливается, окно лезет поверх всего,
     приложение не запускается.
  4. Здесь же — инструкция по шагам.

Одной фразой: воткнул флешку и кабель -> открыл магнитолу -> накидал приложений
-> всё поставилось и работает.

Прошивку программа не трогает — только ставит приложения и меняет их настройки.
Всё это ты делаешь со своей машиной и на свой страх и риск.

────────────────────────────────────────────────────────

ПОДРОБНО ПО ШАГАМ

ЧТО НУЖНО ОДИН РАЗ
- Установить ADB: открой PowerShell и выполни    winget install Google.PlatformTools
  потом закрой и снова открой эту программу.
- Кабель: обычный USB в ноутбук, Type-C в USB-порт машины.
- USB-флешка (данные с неё сотрутся).


ВКЛАДКА «ОТКРЫТЬ ADB»
Здесь снимается код, которым открывается ADB (без него на новой прошивке никак).

  1. В машине: приложение «Телефон» -> набери *#32279 -> раздел ADB ->
     верхний переключатель Adb Switch -> Open. На экране появятся QR-код и поле ввода.
  2. В программе: «Подготовить флешку» (отформатирует в FAT32 и запишет служебный файл).
  3. Вставь флешку в USB машины. Подожди на экране «Android OK / QNX OK». Вынь флешку.
     ВАЖНО: QR-код не закрывай.
  4. Вставь флешку в ноутбук -> «Показать код». Программа покажет 6 символов и скопирует их.
  5. Введи эти 6 символов в поле под QR на экране машины (регистр важен) -> левая кнопка.
     ADB открыт.

ADB закрывается после каждой перезагрузки машины. Заново снимать код нужно только когда
хочешь поставить новые приложения — уже установленные никуда не денутся.
«Очистить старые логи» — если снимаешь код повторно, убери старые папки с флешки.


ВКЛАДКА «ПРИЛОЖЕНИЯ»
Сначала открой ADB (см. выше) и подключи ноутбук к машине кабелем.

  «Установить приложения из папки» — выбери папку с файлами .apk, программа поставит
   всё разом в обход блокировки. В конце покажет, сколько встало и сколько нет.

  «Выдать все разрешения всем приложениям» — пройдётся по всем установленным и выдаст
   каждому все возможные разрешения (микрофон, память, геолокация и т.д.). Часть
   системных разрешений не выдаётся — это нормально.


ВКЛАДКА «ФИКСЫ»
Здесь решения частых проблем. Для всех кнопок нужен открытый ADB и подключённый кабель.

  «Wi-Fi навсегда» — включает Wi-Fi и запрещает ему засыпать и выключаться сам.
   Нужна, чтобы не дёргать Wi-Fi по сто раз.

  «Настройки Wi-Fi» — открывает экран Wi-Fi ПРЯМО НА МАГНИТОЛЕ (на новой прошивке он
   спрятан). Нужен один раз: выбрать свою точку доступа и ввести пароль. После этого,
   вместе с «Wi-Fi навсегда», магнитола цепляется к точке сама, без инженерного меню.
   Порядок: сначала «Wi-Fi навсегда», потом «Настройки Wi-Fi» и подключись к точке.
   Совет: на телефоне сделай правило «подключился по Bluetooth к машине -> включить
   раздачу» — тогда точка поднимается автоматически, как только садишься в машину.

  «Настройки Bluetooth» — открывает экран Bluetooth на магнитоле, чтобы привязать телефон
   (звонки, музыка).

  «Убрать окна поверх» — если какое-то приложение постоянно вылезает поверх всего
   (на сплите, в меню, в доке) — эта кнопка снимает наложение сразу у всех таких
   приложений. Нужные моды (сплит, док, медиа) не трогает.

  «Починить все приложения» — проходит по всем установленным: включает отключённые,
   выдаёт все разрешения. Если приложение не подходит по версии Android — назовёт его
   поимённо (значит, нужна версия постарше).

  «Починить» (одно) — впиши имя пакета конкретного приложения и разбери именно его.


ЕСЛИ ПРИЛОЖЕНИЕ НЕ ЗАПУСКАЕТСЯ — программа назовёт причину:
  - не хватало разрешений -> она их выдаст;
  - нужна более новая версия Android, чем на машине -> так и напишет, ищи версию постарше;
  - у приложения нет значка -> это фоновый сервис или виджет, запускать нечего;
  - если и после этого не стартует -> обычно ему нужны сервисы Google (их на машине нет).


КОРОТКО ПО ПОРЯДКУ ДЛЯ НОВИЧКА
  1) Установи ADB (winget, один раз).
  2) Вкладка «Открыть ADB»: подготовь флешку -> сними код -> введи под QR.
  3) Подключи ноутбук к машине кабелем.
  4) Вкладка «Приложения»: поставь нужные .apk -> выдай все разрешения.
  5) Вкладка «Фиксы»: «Wi-Fi навсегда» + «Настройки Wi-Fi» (подключись к точке).
  6) Что-то не работает -> вкладка «Фиксы» -> «Починить все приложения».
"@
$g.Text=[regex]::Replace($gt,'\r?\n',"`r`n")

Say ("ADB: "+($(if($script:ADB){"найден"}else{"НЕ найден — см. вкладку «Как пользоваться»"})))
Say "Готово к работе. Начни с вкладки «Открыть ADB»."
[void]$form.ShowDialog()
