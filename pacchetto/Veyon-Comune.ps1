<#
  Funzioni comuni per Veyon (carrelli e PC dei docenti). Si usa con ". .\Veyon-Comune.ps1".
  Solo caratteri ASCII (Windows PowerShell 5.1).
#>

$script:VBase    = Join-Path $env:ProgramData 'GestioneCarrello'
$script:VLog     = Join-Path $script:VBase 'log.txt'
$script:VSimula  = $false

# versione e hash dell'installer di Veyon: scaricato SOLO dal sito ufficiale (GitHub veyon/veyon)
$script:VeyonVersione = '4.11.4.0'
$script:VeyonFile     = 'veyon-4.11.4.0-win64-setup.exe'
$script:VeyonUrl      = 'https://github.com/veyon/veyon/releases/download/v4.11.4/veyon-4.11.4.0-win64-setup.exe'
$script:VeyonSha256   = 'bb428d1779a4e54055c8439c069e824904377ddc2e76b5e273cabd9d867f43ed'
$script:VeyonChiave   = 'docenti'

function Write-VLog([string]$msg, [string]$level = 'INFO') {
    $line = '{0} [{1}] VEYON: {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $level, $msg
    Write-Host $line
    if ($script:VSimula) { return }
    try {
        if (-not (Test-Path $script:VBase)) { New-Item -ItemType Directory -Path $script:VBase -Force | Out-Null }
        Add-Content -Path $script:VLog -Value $line -Encoding UTF8
    } catch { }
}

# legge Rete-Veyon.txt (chiave=valore, # commenti)
function Get-ReteVeyon([string]$dir) {
    $h = @{
        SubnetDocenti = '192.168.120.0/24'
        PCCarrello1   = '14'
        PCCarrello2   = '24'
        HostCarrello1 = 'c1-{nn}'
        HostCarrello2 = 'c2-{nn}'
        SshDa         = 'LocalSubnet'
        WifiClasse    = 'SanTommaso_WiFi'
        ScreensaverMinuti = '10'
    }
    $f = Join-Path $dir 'Rete-Veyon.txt'
    if (Test-Path -LiteralPath $f) {
        foreach ($l in (Get-Content -LiteralPath $f)) {
            $t = ($l -replace '#.*$', '').Trim()
            if ($t -match '^([A-Za-z0-9]+)\s*=\s*(.+)$') { $h[$Matches[1]] = $Matches[2].Trim() }
        }
    }
    return $h
}

# "c1-{nn}" -> c1-05 ; "192.168.110.{n+100}" -> 192.168.110.105
function Expand-HostPattern([string]$pattern, [int]$n) {
    $s = $pattern -replace '\{nn\}', ('{0:00}' -f $n)
    $s = [regex]::Replace($s, '\{n(?:\+(\d+))?\}', {
        param($m)
        $add = 0
        if ($m.Groups[1].Success) { $add = [int]$m.Groups[1].Value }
        [string]($n + $add)
    })
    return $s
}

function Get-VeyonCli {
    foreach ($p in "$env:ProgramFiles\Veyon\veyon-cli.exe", "$env:ProgramFiles\Veyon\veyon-wcli.exe") {
        if (Test-Path -LiteralPath $p) { return $p }
    }
    return $null
}

function Invoke-VeyonCli {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
    $cli = Get-VeyonCli
    if (-not $cli) { throw 'Veyon non installato' }
    $out = & $cli @Arguments 2>&1
    $code = $LASTEXITCODE
    return [pscustomobject]@{ Code = $code; Output = (($out | Out-String).Trim()) }
}

function Get-VeyonInstalledVersion {
    $cli = Get-VeyonCli
    if (-not $cli) { return $null }
    try { return (Get-Item -LiteralPath $cli).VersionInfo.ProductVersion } catch { return 'sconosciuta' }
}

# trova (o scarica con verifica dell'hash) l'installer di Veyon; restituisce il percorso o $null
function Get-VeyonInstaller([string]$dir) {
    $local = Join-Path $dir ('Installer\' + $script:VeyonFile)
    if (-not (Test-Path -LiteralPath $local)) { $local = Join-Path $dir ('..\Installer\' + $script:VeyonFile) }
    if (-not (Test-Path -LiteralPath $local)) { $local = Join-Path $dir $script:VeyonFile }
    if (Test-Path -LiteralPath $local) {
        if ((Get-FileHash -LiteralPath $local -Algorithm SHA256).Hash -ieq $script:VeyonSha256) { return $local }
        Write-VLog "L'installer locale $local ha un hash diverso da quello atteso: lo ignoro" 'AVVISO'
    }
    $tmp = Join-Path $env:TEMP $script:VeyonFile
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Write-VLog "Scarico Veyon da $($script:VeyonUrl)"
        Invoke-WebRequest -Uri $script:VeyonUrl -OutFile $tmp -UseBasicParsing
        $h = (Get-FileHash -LiteralPath $tmp -Algorithm SHA256).Hash
        if ($h -ine $script:VeyonSha256) {
            Write-VLog "Hash dell'installer scaricato NON valido ($h): lo cancello" 'ERRORE'
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
            return $null
        }
        return $tmp
    } catch {
        Write-VLog "Download di Veyon non riuscito: $($_.Exception.Message)" 'ERRORE'
        return $null
    }
}

# $Master = $true sui PC dei docenti; $false sui carrelli (solo Service)
function Install-Veyon([string]$dir, [bool]$Master) {
    $v = Get-VeyonInstalledVersion
    $haMaster = Test-Path -LiteralPath "$env:ProgramFiles\Veyon\veyon-master.exe"
    if ($v -and $v.StartsWith($script:VeyonVersion.Substring(0, 6)) -and ($haMaster -eq $Master)) {
        Write-VLog "Veyon $v gia' installato"
        return $true
    }
    if ($script:VSimula) { Write-VLog "[SIMULAZIONE] installerei Veyon $($script:VeyonVersion) (Master=$Master)"; return $true }
    $exe = Get-VeyonInstaller $dir
    if (-not $exe) { return $false }
    $argsList = @('/S')
    if (-not $Master) { $argsList += '/NoMaster'; $argsList += '/NoStartMenuFolder' }
    Write-VLog ("Installo Veyon: {0} {1}" -f $script:VeyonFile, ($argsList -join ' '))
    $p = Start-Process -FilePath $exe -ArgumentList $argsList -Wait -PassThru
    if ($p.ExitCode -ne 0) { Write-VLog "Installer di Veyon: codice $($p.ExitCode)" 'AVVISO' }
    if (-not (Get-VeyonCli)) { Write-VLog 'Veyon non risulta installato' 'ERRORE'; return $false }
    return $true
}

function Set-VeyonConfig([string]$key, [string]$value) {
    $r = Invoke-VeyonCli config set $key $value
    if ($r.Code -ne 0) { Write-VLog "config set $key non riuscito: $($r.Output)" 'AVVISO' }
}

# Veyon apre da solo le sue regole di firewall: le togliamo e le sostituiamo con le nostre
function Remove-VeyonFirewallRules {
    Get-NetFirewallRule -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -like 'Veyon*' -and $_.Direction -eq 'Inbound' } |
        Remove-NetFirewallRule -ErrorAction SilentlyContinue
}

# gestione remota SSH con chiave (come nei carrelli); $remote = LocalSubnet oppure elenco di subnet
function Enable-SshRemoto([string]$dir, [string]$remote) {
    if ($script:VSimula) { Write-VLog '[SIMULAZIONE] abiliterei la gestione remota SSH'; return }
    try {
        if (-not (Get-Service -Name sshd -ErrorAction SilentlyContinue)) {
            $msi = Get-ChildItem -LiteralPath $dir -Filter 'OpenSSH-Win64*.msi' -ErrorAction SilentlyContinue | Select-Object -First 1
            if (-not $msi) { Write-VLog 'Manca OpenSSH-Win64*.msi accanto allo script: SSH non installato' 'AVVISO'; return }
            Start-Process msiexec.exe -ArgumentList ('/i "{0}" /qn /norestart' -f $msi.FullName) -Wait | Out-Null
        }
        if (-not (Get-Service -Name sshd -ErrorAction SilentlyContinue)) { Write-VLog 'OpenSSH non installato' 'AVVISO'; return }
        $cfg = Join-Path $env:ProgramData 'ssh\sshd_config'
        if (-not (Test-Path $cfg)) {
            Set-Service -Name sshd -StartupType Automatic
            Start-Service sshd; Start-Sleep -Seconds 3; Stop-Service sshd -ErrorAction SilentlyContinue
            if (-not (Test-Path $cfg)) {
                $def = Join-Path $env:ProgramFiles 'OpenSSH\sshd_config_default'
                if (Test-Path $def) { New-Item -ItemType Directory -Path (Split-Path $cfg) -Force | Out-Null; Copy-Item -LiteralPath $def -Destination $cfg }
            }
        }
        $restart = $false
        if (Test-Path $cfg) {
            $text = Get-Content -LiteralPath $cfg -Raw
            if ($text -notmatch 'Carrello-gestione') {
                Set-Content -LiteralPath $cfg -Value ("# Carrello-gestione`r`nPasswordAuthentication no`r`nPubkeyAuthentication yes`r`n" + $text) -Encoding ascii
                $restart = $true
            }
        }
        $kf = Join-Path $dir 'chiave-mac.pub'
        if (-not (Test-Path -LiteralPath $kf)) { Write-VLog 'Manca chiave-mac.pub: SSH non configurato' 'AVVISO'; return }
        $keyText = (Get-Content -LiteralPath $kf -Raw).Trim()
        $keyFile = Join-Path $env:ProgramData 'ssh\administrators_authorized_keys'
        $cur = if (Test-Path $keyFile) { (Get-Content -LiteralPath $keyFile -Raw).Trim() } else { '' }
        if ($cur -ne $keyText) { Set-Content -LiteralPath $keyFile -Value $keyText -Encoding ascii }
        & icacls.exe $keyFile /inheritance:r /grant:r '*S-1-5-32-544:F' '*S-1-5-18:F' | Out-Null
        New-Item -Path 'HKLM:\SOFTWARE\OpenSSH' -Force | Out-Null
        New-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name 'DefaultShell' -PropertyType String -Force -Value 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' | Out-Null
        Get-NetFirewallRule -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like '*OpenSSH*' -and $_.Name -ne 'Carrello-SSH' -and $_.Direction -eq 'Inbound' } | Disable-NetFirewallRule
        Remove-NetFirewallRule -Name 'Carrello-SSH' -ErrorAction SilentlyContinue
        New-NetFirewallRule -Name 'Carrello-SSH' -DisplayName 'SSH dalla rete locale (gestione)' -Direction Inbound -Protocol TCP -LocalPort 22 -Action Allow -RemoteAddress ($remote -split '\s*,\s*') -Profile Any | Out-Null
        Set-Service -Name sshd -StartupType Automatic
        if ((Get-Service sshd).Status -ne 'Running') { Start-Service sshd } elseif ($restart) { Restart-Service sshd }
        Write-VLog 'Gestione remota (SSH con chiave) attiva'
    } catch { Write-VLog "SSH non configurato: $($_.Exception.Message)" 'AVVISO' }
}
