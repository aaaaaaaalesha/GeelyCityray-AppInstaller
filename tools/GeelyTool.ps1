# ================================================================
#  Geely Cityray - ADB QR Tool
#  1) Подготовка флешки: FAT32 + svlog.flag  (в один клик)
#  2) Чтение проверочного кода с флешки (logs_*/bugreport-*.zip)
#  Алгоритм кода: HKDF (HMAC-SHA256) -> 6 байт -> [0-9A-Za-z]
#  Проверено на эталонном векторе RFC 5869 и на реальном ГУ.
# ================================================================
param([switch]$Test)

# ---------- HKDF / генератор кода ----------
function HmacSha256([byte[]]$key,[byte[]]$msg){
  $h = New-Object System.Security.Cryptography.HMACSHA256
  $h.Key = $key
  return $h.ComputeHash($msg)
}
function HkdfExtract([byte[]]$salt,[byte[]]$ikm){ return HmacSha256 $salt $ikm }
function HkdfExpand([byte[]]$prk,[byte[]]$info,[int]$len){
  $t=@(); $okm=@(); $n=[math]::Floor(($len+31)/32)
  for($i=0;$i -lt $n;$i++){
    $inp=@(); $inp+=$t; $inp+=$info; $inp+=[byte]($i+1)
    $t = HmacSha256 $prk ([byte[]]$inp); $okm+=$t
  }
  return ([byte[]]$okm)[0..($len-1)]
}
function EncodeAlnum([byte[]]$data){
  $cs="0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
  -join ($data | ForEach-Object { $cs[($_ -band 0xFF)%62] })
}
function Compute-Code([int[]]$salt,[int[]]$password,[string]$sn){
  $saltB=[byte[]]($salt|ForEach-Object{[byte]($_ -band 0xFF)})
  $pwB=[byte[]]($password|ForEach-Object{[byte]($_ -band 0xFF)})
  $info=[System.Text.Encoding]::UTF8.GetBytes($sn)
  $prk=HkdfExtract $saltB $pwB
  $six=HkdfExpand $prk $info 6
  return EncodeAlnum $six
}

# Ищет logs_*/bugreport-*.zip на диске $root, возвращает объект с кодом или ошибкой
function Get-QRResult([string]$root){
  $res=[ordered]@{ ok=$false; code=$null; sn=$null; msg=$null; folder=$null }
  $logs = Get-ChildItem -Path $root -Directory -Filter "logs_*" -ErrorAction SilentlyContinue | Sort-Object Name | Select-Object -Last 1
  if(-not $logs){ $res.msg="На флешке ($root) нет папки logs_*. Сначала сделайте выгрузку логов в машине (Adb Switch Open + флешка)."; return [pscustomobject]$res }
  $res.folder=$logs.FullName
  $zip = Get-ChildItem -Path $logs.FullName -Filter "bugreport-*.zip" -ErrorAction SilentlyContinue | Sort-Object Name | Select-Object -Last 1
  if(-not $zip){ $res.msg="В $($logs.Name) нет bugreport-*.zip. Выгрузка не завершилась (не дождались Android OK / QNX OK?)."; return [pscustomobject]$res }
  try{
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $za=[System.IO.Compression.ZipFile]::OpenRead($zip.FullName)
    try{
      foreach($e in $za.Entries){
        if($e.FullName -notlike "*.txt"){ continue }
        $sr=New-Object System.IO.StreamReader($e.Open()); $c=$sr.ReadToEnd(); $sr.Close()
        $sM=[regex]::Matches($c,'salt\s*=\s*\[(.*?)\]')
        $pM=[regex]::Matches($c,'password\s*=\s*\[(.*?)\]')
        $nM=[regex]::Matches($c,' sn\s*=\s*([A-Za-z0-9_\-.]+)')
        if($sM.Count -and $pM.Count -and $nM.Count){
          $salt=$sM[$sM.Count-1].Groups[1].Value.Split(',')|ForEach-Object{[int]$_.Trim()}
          $pw=$pM[$pM.Count-1].Groups[1].Value.Split(',')|ForEach-Object{[int]$_.Trim()}
          $sn=$nM[$nM.Count-1].Groups[1].Value.Trim()
          $res.code=Compute-Code $salt $pw $sn; $res.sn=$sn; $res.ok=$true
          return [pscustomobject]$res
        }
      }
      $res.msg="В bugreport не найдены поля salt/password/sn."
    } finally { $za.Dispose() }
  } catch { $res.msg="Ошибка чтения архива: $($_.Exception.Message)" }
  return [pscustomobject]$res
}

# ---------- Работа с флешкой ----------
function Get-FlashVolumes(){
  Get-CimInstance Win32_LogicalDisk | Where-Object { $_.DriveType -eq 2 } |
    Select-Object DeviceID, @{N='FS';E={$_.FileSystem}}, VolumeName,
      @{N='SizeGB';E={[math]::Round($_.Size/1GB,1)}}
}
function Get-FlashDisks(){ Get-Disk | Where-Object { $_.BusType -eq 'USB' } }

function Format-FlashFAT32([int]$diskNumber){
  $disk = Get-Disk -Number $diskNumber
  $diskMB=[int]($disk.Size/1MB)
  $partMB=[math]::Min(32000, $diskMB-50)
  $script=@"
select disk $diskNumber
clean
create partition primary size=$partMB
format fs=fat32 quick label=GEELY
assign
"@
  $tmp=[System.IO.Path]::GetTempFileName()
  $script | Out-File -FilePath $tmp -Encoding ascii
  $out = diskpart /s $tmp 2>&1 | Out-String
  Remove-Item $tmp -Force -ErrorAction SilentlyContinue
  Start-Sleep -Seconds 2
  # найти новую букву раздела и положить svlog.flag
  $part = Get-Partition -DiskNumber $diskNumber -ErrorAction SilentlyContinue | Where-Object DriveLetter | Select-Object -First 1
  if($part){
    $drive="$($part.DriveLetter):"
    New-Item -ItemType File -Path "$drive\svlog.flag" -Force | Out-Null
    return @{ ok=$true; drive=$drive; out=$out }
  }
  return @{ ok=$false; drive=$null; out=$out }
}

function Clean-OldLogs([string]$root){
  $n=0
  Get-ChildItem -Path $root -Directory -Filter "logs_*" -ErrorAction SilentlyContinue | ForEach-Object {
    cmd /c rmdir /s /q "`"$($_.FullName)`"" ; $n++
  }
  return $n
}

# ---------- Самопроверка (без GUI) ----------
if($Test){
  $ikm=[byte[]](@(0x0b)*22); $salt=[byte[]](0x00..0x0c); $info=[byte[]](0xf0..0xf9)
  $prk=HkdfExtract $salt $ikm; $okm=HkdfExpand $prk $info 42
  $okmHex=($okm|ForEach-Object{$_.ToString('x2')}) -join ''
  $rfc='3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865'
  Write-Host ("HKDF RFC5869 self-test: {0}" -f ($okmHex -eq $rfc))
  Write-Host ("Encoder test (expect 01Az07): {0}" -f (EncodeAlnum ([byte[]](0,1,10,61,62,255))))
  return
}

# ---------- Самоповышение прав (нужно для форматирования) ----------
$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if(-not $admin){
  Start-Process powershell -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
  exit
}

# ---------- GUI ----------
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$form=New-Object Windows.Forms.Form
$form.Text="Geely Cityray — ADB QR Tool"
$form.Size=New-Object Drawing.Size(560,560)
$form.StartPosition="CenterScreen"
$form.Font=New-Object Drawing.Font("Segoe UI",10)

$lblDrive=New-Object Windows.Forms.Label
$lblDrive.Location='20,15'; $lblDrive.Size='510,40'; $lblDrive.Text="Флешка: (обновите)"
$form.Controls.Add($lblDrive)

$btnRefresh=New-Object Windows.Forms.Button
$btnRefresh.Location='20,55'; $btnRefresh.Size='510,30'; $btnRefresh.Text="⟳ Обновить список флешек"
$form.Controls.Add($btnRefresh)

$btnPrep=New-Object Windows.Forms.Button
$btnPrep.Location='20,95'; $btnPrep.Size='510,55'
$btnPrep.Text="1.  Подготовить флешку  (FAT32 + svlog.flag)"
$btnPrep.BackColor=[Drawing.Color]::FromArgb(220,235,255)
$form.Controls.Add($btnPrep)

$btnCode=New-Object Windows.Forms.Button
$btnCode.Location='20,160'; $btnCode.Size='510,55'
$btnCode.Text="2.  Показать код с флешки"
$btnCode.BackColor=[Drawing.Color]::FromArgb(220,255,225)
$form.Controls.Add($btnCode)

$lblCode=New-Object Windows.Forms.Label
$lblCode.Location='20,225'; $lblCode.Size='510,70'
$lblCode.TextAlign='MiddleCenter'
$lblCode.Font=New-Object Drawing.Font("Consolas",34,[Drawing.FontStyle]::Bold)
$lblCode.ForeColor=[Drawing.Color]::FromArgb(0,120,0)
$lblCode.Text="——————"
$form.Controls.Add($lblCode)

$btnClean=New-Object Windows.Forms.Button
$btnClean.Location='20,300'; $btnClean.Size='510,28'
$btnClean.Text="Очистить старые logs_* с флешки (перед повторной разблокировкой)"
$form.Controls.Add($btnClean)

$log=New-Object Windows.Forms.TextBox
$log.Location='20,335'; $log.Size='510,175'
$log.Multiline=$true; $log.ScrollBars='Vertical'; $log.ReadOnly=$true
$log.Font=New-Object Drawing.Font("Consolas",9)
$form.Controls.Add($log)

$script:selected=$null
function Say($t){ $log.AppendText((Get-Date -Format "HH:mm:ss") + "  " + $t + "`r`n") }

function Refresh(){
  $vols=@(Get-FlashVolumes)
  if($vols.Count -eq 0){ $lblDrive.Text="Флешка: НЕ найдена. Вставьте USB-флешку и нажмите Обновить."; $script:selected=$null; return }
  $v=$vols[0]
  $script:selected=$v
  $lblDrive.Text=("Флешка: {0}  ({1}, {2} ГБ{3})" -f $v.DeviceID,$v.FS,$v.SizeGB, ($(if($v.VolumeName){", метка "+$v.VolumeName}else{""})))
  if($vols.Count -gt 1){ $lblDrive.Text+="   [найдено {0}, взята первая]" -f $vols.Count }
}

$btnRefresh.Add_Click({ Refresh; Say "Список обновлён." })

$btnPrep.Add_Click({
  $disks=@(Get-FlashDisks)
  if($disks.Count -eq 0){ [Windows.Forms.MessageBox]::Show("USB-флешка не найдена.","Нет флешки"); return }
  if($disks.Count -gt 1){ [Windows.Forms.MessageBox]::Show("Подключено несколько USB-накопителей. Оставьте только нужную флешку, чтобы не отформатировать лишнее.","Внимание"); return }
  $d=$disks[0]
  $msg="Будет ПОЛНОСТЬЮ стёрт и отформатирован в FAT32 диск:`n`n  Диск $($d.Number): $($d.FriendlyName)  ($([math]::Round($d.Size/1GB,1)) ГБ)`n`nВсе данные на нём пропадут. Продолжить?"
  if([Windows.Forms.MessageBox]::Show($msg,"Подтверждение форматирования",'YesNo','Warning') -ne 'Yes'){ return }
  Say "Форматирую диск $($d.Number) в FAT32..."
  $form.Enabled=$false
  try{
    $r=Format-FlashFAT32 $d.Number
    if($r.ok){ Say "Готово: $($r.drive)  FAT32, метка GEELY, svlog.flag записан."; Say "Можно нести флешку в машину." ; Refresh }
    else{ Say "Не удалось определить букву после форматирования. Вывод diskpart:"; Say $r.out }
  } catch { Say "ОШИБКА: $($_.Exception.Message)" }
  finally { $form.Enabled=$true }
})

$btnCode.Add_Click({
  Refresh
  if(-not $script:selected){ Say "Флешка не найдена."; return }
  $root="$($script:selected.DeviceID)\"
  Say "Читаю логи с $root ..."
  $r=Get-QRResult $root
  if($r.ok){
    $lblCode.Text=$r.code
    [Windows.Forms.Clipboard]::SetText($r.code)
    Say "КОД: $($r.code)   (скопирован в буфер обмена)"
    Say "SN ГУ: $($r.sn)"
    Say "Вводите код в поле под QR на экране машины, регистр важен!"
  } else {
    $lblCode.Text="——————"
    Say $r.msg
  }
})

$btnClean.Add_Click({
  Refresh
  if(-not $script:selected){ Say "Флешка не найдена."; return }
  $root="$($script:selected.DeviceID)\"
  $n=Clean-OldLogs $root
  Say "Удалено папок logs_*: $n. svlog.flag оставлен."
  if(-not (Test-Path "$root\svlog.flag")){ New-Item -ItemType File -Path "$root\svlog.flag" -Force | Out-Null; Say "svlog.flag восстановлен." }
})

Refresh
Say "Готово к работе. Порядок: 1) Подготовить флешку -> вставить в машину (Adb Switch Open, левый USB) -> дождаться Android OK/QNX OK -> вынуть -> 2) Показать код."
[void]$form.ShowDialog()
