<#
.SYNOPSIS
  Aggiornamento automatico del PC del carrello. Lo lancia l'attivita' pianificata
  "Carrello-Aggiorna" (all'avvio e ogni giorno, solo se c'e' la rete). Nessuna domanda.

.DESCRIPTION
  1. Scarica manifest.json e manifest.sig da GitHub.
  2. Verifica la FIRMA (chiave pubblica incorporata qui sotto): se non e' valida non fa nulla.
  3. Controlla che la versione (build) sia piu' alta di quella installata e che il carrello
     di questo PC sia tra quelli ammessi (rilascio graduale).
  4. Scarica i file, ne verifica l'hash SHA256, li mette in C:\ProgramData\GestioneCarrello\pacchetto.
  5. Lancia Installa-PC.ps1 -Aggiorna (senza backup, senza riavvio, senza toccare password).

.PARAMETER Origine
  Per le prove: cartella o indirizzo web al posto di GitHub (la firma resta obbligatoria).
.PARAMETER Forza
  Riapplica anche se la versione e' la stessa.
#>
[CmdletBinding()]
param([string]$Origine, [switch]$Forza)

$ErrorActionPreference = 'Stop'
$Base      = Join-Path $env:ProgramData 'GestioneCarrello'
$LogFile   = Join-Path $Base 'log.txt'
$Pacchetto = Join-Path $Base 'pacchetto'
$Scarico   = Join-Path $Base 'scarico'
$BuildFile = Join-Path $Base 'build.txt'
$StatoFile = Join-Path $Base 'aggiornamento.json'
if (-not $Origine) { $Origine = 'https://raw.githubusercontent.com/pparide/carrello-pc/main/pacchetto' }

# chiave pubblica di firma (la privata e' solo sul Mac del docente)
$ChiavePubblica = '<RSAKeyValue><Modulus>kjiiqQOycI5PkvyV8S+DgMqN7WgFoqxIZeuWg34S8U98As0Rt8q9a9YMPN4x/ahA33emzwy3E9BwXUv7uB5EhiSiNh0AAMyPCoYPbkr1+yIlTvjprjtbAubTRAoegEezyZGQPu7GWyspdv8YrhcLneonZdzwDKquav+SvEPamu7LJjNC17oCY+67kI9VJKQ14P/yT2qpDeLGfe6O/N+XfxC90HN8ETmd4YnClckmXCOtcv+82sBpNSPQY7Bd8oWU6jHZysPMiHxXzcAn/0tPJSSRuJkTvCe3PkUQ4UKj/I0/quK9qqav2H05B3WtOCzZ7saguc0xxnc1yclKioJBGJXBoFjd0j6uaosdG0iM0NescLyBPrxaNWvfpYfpDLDkR/MjwGbZzRZitx1LgYaau3OJwAHbujV+khv9+4kgQgsVZ6SsfBTWvKsoAPyBb2ZvnYweJn18R3a+ycIlmxUg9/7PVUiSUcqKGuBXguwu6zDiEkIk8QMnr0spZGihr0dd</Modulus><Exponent>AQAB</Exponent></RSAKeyValue>'

function Write-Log([string]$msg, [string]$level = 'INFO') {
    try { Add-Content -Path $LogFile -Value ('{0} [{1}] AGGIORNA: {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $level, $msg) -Encoding UTF8 } catch { }
}
function Get-BatteriaInfo {
    try {
        $tmp = Join-Path $env:TEMP 'bat.xml'
        & powercfg.exe /batteryreport /output $tmp /xml 2>&1 | Out-Null
        [xml]$x = Get-Content -LiteralPath $tmp -Raw
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        $b = @($x.BatteryReport.Batteries.Battery)[0]
        $c = (Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue | Select-Object -First 1).EstimatedChargeRemaining
        return [pscustomobject]@{ SalutePercento = [int](100 * [double]$b.FullChargeCapacity / [double]$b.DesignCapacity); Cicli = [int]$b.CycleCount; CaricaPercento = $c }
    } catch { return $null }
}
function Set-Stato([string]$esito, $build) {
    try {
        [pscustomobject]@{ UltimoControllo = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'); Esito = $esito; BuildInstallata = $build; Pc = $env:COMPUTERNAME; Batteria = (Get-BatteriaInfo) } |
            ConvertTo-Json | Set-Content -Path $StatoFile -Encoding UTF8
    } catch { }
}
function Get-Bytes([string]$nome, [switch]$NoCache) {
    if ($Origine -match '^https?://') {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $u = $Origine.TrimEnd('/') + '/' + (($nome.Split('/') | ForEach-Object { [uri]::EscapeDataString($_) }) -join '/')
        if ($NoCache) { $u += '?c=' + [DateTime]::UtcNow.Ticks }
        $r = Invoke-WebRequest -Uri $u -UseBasicParsing -TimeoutSec 60
        $ms = New-Object System.IO.MemoryStream
        [void]$r.RawContentStream.Seek(0, [System.IO.SeekOrigin]::Begin)
        $r.RawContentStream.CopyTo($ms)
        return ,$ms.ToArray()
    }
    return ,[System.IO.File]::ReadAllBytes((Join-Path $Origine $nome))
}
function Get-Sha256([byte[]]$bytes) {
    $h = [System.Security.Cryptography.SHA256]::Create()
    return ([BitConverter]::ToString($h.ComputeHash($bytes)) -replace '-', '').ToLower()
}

# se l'attivita' di accesso non e' partita dopo l'ultimo avvio (capita al primo accesso), la fa partire
function Start-LogonSeMancato {
    try {
        $boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
        $su = Get-LocalUser -Name 'Studente' -ErrorAction SilentlyContinue
        if (-not $su -or -not (Test-Path "Registry::HKEY_USERS\$($su.SID.Value)")) { return }
        $info = Get-ScheduledTaskInfo -TaskName 'Carrello-Logon' -ErrorAction Stop
        if ($info.LastRunTime -lt $boot -and ((Get-Date) - $boot).TotalMinutes -gt 2) {
            Start-ScheduledTask -TaskName 'Carrello-Logon'
            Write-Log "L'attivita' di accesso non era partita dopo l'avvio: avviata ora"
        }
    } catch { }
}

# Windows Update: a ogni controllo chiede a Windows di cercare, scaricare e installare gli aggiornamenti
function Start-WindowsUpdate {
    try {
        foreach ($svc in 'wuauserv', 'UsoSvc', 'BITS') {
            $x = Get-Service -Name $svc -ErrorAction SilentlyContinue
            if ($x -and $x.StartType -eq 'Disabled') { Set-Service -Name $svc -StartupType Manual }
        }
        $uso = Join-Path $env:WINDIR 'System32\UsoClient.exe'
        if (Test-Path $uso) {
            foreach ($c in 'StartScan', 'StartDownload', 'StartInstall') { Start-Process -FilePath $uso -ArgumentList $c -WindowStyle Hidden; Start-Sleep -Seconds 2 }
        }
        $pend = (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') -or
                (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending')
        Write-Log ("Windows Update: ricerca avviata; riavvio in sospeso: {0}" -f $(if ($pend) { 'si' } else { 'no' }))
    } catch { Write-Log "Windows Update: $($_.Exception.Message)" 'AVVISO' }
}

$mutex = New-Object System.Threading.Mutex($false, 'Global\CarrelloAggiorna')
if (-not $mutex.WaitOne(0)) { exit 0 }
$buildInstallata = 0
Start-LogonSeMancato
Start-WindowsUpdate
try {
    if (Test-Path $BuildFile) { $buildInstallata = [int](Get-Content $BuildFile -Raw).Trim() }

    # 1-2. manifest firmato
    $mBytes = Get-Bytes 'manifest.json' -NoCache
    $sigB64 = [Text.Encoding]::ASCII.GetString((Get-Bytes 'manifest.sig' -NoCache)).Trim()
    $sig    = [Convert]::FromBase64String($sigB64)
    $rsa = New-Object System.Security.Cryptography.RSACryptoServiceProvider
    $rsa.FromXmlString($ChiavePubblica)
    if (-not $rsa.VerifyData($mBytes, 'SHA256', $sig)) {
        Write-Log 'FIRMA NON VALIDA: aggiornamento rifiutato' 'ERRORE'
        Set-Stato 'firma non valida' $buildInstallata
        exit 2
    }
    $m = [Text.Encoding]::UTF8.GetString($mBytes).TrimStart([char]0xFEFF) | ConvertFrom-Json

    # 3. versione e carrello
    $build = [int]$m.build
    if (-not $Forza -and $build -le $buildInstallata) {
        Set-Stato "aggiornato (build $buildInstallata)" $buildInstallata
        exit 0
    }
    if ($env:COMPUTERNAME -notmatch '^C(\d)-(\d{2})$') {
        Write-Log "Nome PC '$($env:COMPUTERNAME)' non nel formato Cn-nn: nessun aggiornamento" 'AVVISO'
        Set-Stato 'nome PC non valido' $buildInstallata
        exit 0
    }
    $cart = [int]$Matches[1]
    if (@($m.carrelli) -notcontains $cart) {
        Set-Stato "build $build non ancora per il carrello $cart" $buildInstallata
        exit 0
    }
    Write-Log "Nuova versione $($m.versione) (build $build, installata $buildInstallata): scarico"

    # 4. scarico e verifica degli hash
    if (Test-Path $Scarico) { Remove-Item $Scarico -Recurse -Force }
    New-Item -ItemType Directory -Path $Scarico -Force | Out-Null
    $scaricoFull = (Resolve-Path $Scarico).Path
    foreach ($p in $m.file.PSObject.Properties) {
        $nome = $p.Name
        if ($nome -notmatch '^[A-Za-z0-9][A-Za-z0-9 _.\-]*(/[A-Za-z0-9][A-Za-z0-9 _.\-]*)*$' -or $nome -match '\.\.') { throw "Nome file non ammesso nel manifest: $nome" }
        $b = Get-Bytes $nome
        if ((Get-Sha256 $b) -ne ([string]$p.Value).ToLower()) { throw "Hash non corrispondente: $nome" }
        $dest = Join-Path $scaricoFull ($nome -replace '/', '\')
        if (-not $dest.StartsWith($scaricoFull)) { throw "Percorso non ammesso: $nome" }
        New-Item -ItemType Directory -Path (Split-Path $dest) -Force | Out-Null
        [System.IO.File]::WriteAllBytes($dest, $b)
    }
    if (-not (Test-Path (Join-Path $Scarico 'Installa-PC.ps1'))) { throw 'Installa-PC.ps1 manca nel pacchetto' }

    # sostituzione del pacchetto locale
    if (Test-Path $Pacchetto) { Remove-Item $Pacchetto -Recurse -Force }
    Move-Item -LiteralPath $Scarico -Destination $Pacchetto
    & icacls.exe $Pacchetto /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)RX' | Out-Null

    # 5. applicazione non interattiva
    Write-Log 'Pacchetto verificato: applico'
    $proc = Start-Process -FilePath 'powershell.exe' -Wait -PassThru -WindowStyle Hidden -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "{0}" -Aggiorna' -f (Join-Path $Pacchetto 'Installa-PC.ps1'))
    if ($proc.ExitCode -ne 0) { throw "Installa-PC.ps1 -Aggiorna e' terminato con codice $($proc.ExitCode)" }
    Set-Content -Path $BuildFile -Value $build -Encoding ascii
    Write-Log "Aggiornamento completato: versione $($m.versione) (build $build)"
    Set-Stato "aggiornato a build $build" $build
} catch {
    Write-Log "Aggiornamento non riuscito: $($_.Exception.Message)" 'ERRORE'
    Set-Stato "errore: $($_.Exception.Message)" $buildInstallata
    exit 1
} finally {
    try { $mutex.ReleaseMutex() } catch { }
}
