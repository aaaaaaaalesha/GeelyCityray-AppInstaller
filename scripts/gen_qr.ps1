# QR verification code generator for Adb Switch (Geely Cityray new firmware)
# Full equivalent of QR.py: reads logs_*/bugreport-*.zip on the flash drive,
# extracts salt/password/sn, computes HKDF(HMAC-SHA256) -> 6 bytes -> 6 chars [0-9A-Za-z].
param([string]$Root)

function HmacSha256([byte[]]$key,[byte[]]$msg){
  $h = New-Object System.Security.Cryptography.HMACSHA256
  $h.Key = $key
  return $h.ComputeHash($msg)
}
function HkdfExtract([byte[]]$salt,[byte[]]$ikm){ return HmacSha256 $salt $ikm }
function HkdfExpand([byte[]]$prk,[byte[]]$info,[int]$len){
  $t=@(); $okm=@(); $n=[math]::Floor(($len+31)/32)
  for($i=0;$i -lt $n;$i++){
    $inp = @(); $inp += $t; $inp += $info; $inp += [byte]($i+1)
    $t = HmacSha256 $prk ([byte[]]$inp)
    $okm += $t
  }
  return ([byte[]]$okm)[0..($len-1)]
}
function EncodeAlnum([byte[]]$data){
  $cs = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
  -join ($data | ForEach-Object { $cs[ ($_ -band 0xFF) % 62 ] })
}
function Compute([int[]]$salt,[int[]]$password,[string]$sn){
  $saltB = [byte[]]($salt | ForEach-Object { [byte]($_ -band 0xFF) })
  $pwB   = [byte[]]($password | ForEach-Object { [byte]($_ -band 0xFF) })
  $info  = [System.Text.Encoding]::UTF8.GetBytes($sn)
  $prk = HkdfExtract $saltB $pwB
  $six = HkdfExpand $prk $info 6
  return EncodeAlnum $six
}

# --- Self-test: HKDF against RFC 5869 test vector A.1 ---
if($Root -eq "SELFTEST"){
  $ikm  = [byte[]](@(0x0b)*22)
  $salt = [byte[]](0x00..0x0c)
  $info = [byte[]](0xf0..0xf9)
  $prk = HkdfExtract $salt $ikm
  $prkHex = ($prk | ForEach-Object { $_.ToString('x2') }) -join ''
  $okm = HkdfExpand $prk $info 42
  $okmHex = ($okm | ForEach-Object { $_.ToString('x2') }) -join ''
  $expPrk = '077709362c2e32df0ddc3f0dc47bba6390b6c73bb50f9c3122ec844ad7c2b3e5'
  $expOkm = '3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b8871185865'
  Write-Host ("PRK match: {0}" -f ($prkHex -eq $expPrk))
  Write-Host ("OKM match: {0}" -f ($okmHex -eq $expOkm))
  # sanity of alnum encoder
  Write-Host ("ENC test : {0}" -f (EncodeAlnum ([byte[]](0,1,10,61,62,255))))
  return
}

# --- Normal mode: find flash logs and compute code ---
if(-not $Root){ $Root = (Get-Location).Path }
$logs = Get-ChildItem -Path $Root -Directory -Filter "logs_*" -ErrorAction SilentlyContinue | Sort-Object Name | Select-Object -Last 1
if(-not $logs){ Write-Host "No logs_* folder found in $Root" -ForegroundColor Yellow; return }
Write-Host "Logs folder: $($logs.FullName)"
$zip = Get-ChildItem -Path $logs.FullName -Filter "bugreport-*.zip" -ErrorAction SilentlyContinue | Sort-Object Name | Select-Object -Last 1
if(-not $zip){ Write-Host "No bugreport-*.zip found" -ForegroundColor Yellow; return }
Write-Host "Archive: $($zip.FullName)"

Add-Type -AssemblyName System.IO.Compression.FileSystem
$za = [System.IO.Compression.ZipFile]::OpenRead($zip.FullName)
try{
  foreach($e in $za.Entries){
    if($e.FullName -notlike "*.txt"){ continue }
    $sr = New-Object System.IO.StreamReader($e.Open())
    $content = $sr.ReadToEnd(); $sr.Close()
    $saltM = [regex]::Matches($content,'salt\s*=\s*\[(.*?)\]')
    $pwM   = [regex]::Matches($content,'password\s*=\s*\[(.*?)\]')
    $snM   = [regex]::Matches($content,' sn\s*=\s*([A-Za-z0-9_\-.]+)')
    if($saltM.Count -and $pwM.Count -and $snM.Count){
      $salt = $saltM[$saltM.Count-1].Groups[1].Value.Split(',') | ForEach-Object {[int]$_.Trim()}
      $pw   = $pwM[$pwM.Count-1].Groups[1].Value.Split(',') | ForEach-Object {[int]$_.Trim()}
      $sn   = $snM[$snM.Count-1].Groups[1].Value.Trim()
      Write-Host "Match in: $($e.FullName)"
      Write-Host "sn=$sn  salt_len=$($salt.Count)  password_len=$($pw.Count)"
      $code = Compute $salt $pw $sn
      Write-Host ("`n================  CODE: {0}  ================`n" -f $code) -ForegroundColor Green
      return
    }
  }
  Write-Host "salt/password/sn not found in any .txt" -ForegroundColor Yellow
} finally { $za.Dispose() }
