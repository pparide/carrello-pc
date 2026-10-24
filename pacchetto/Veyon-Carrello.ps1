<#
.SYNOPSIS
  Installa Veyon Service su un PC del carrello: i docenti possono vedere/bloccare lo
  schermo, aprire un sito, inviare file e messaggi. Nessuna domanda.

.DESCRIPTION
  - Installer ufficiale (hash SHA256 fissato), solo Service (senza Master).
  - Autenticazione con chiave: sul PC resta solo la chiave PUBBLICA "docenti"
    (file veyon-docenti-pubblica.key). Senza la chiave privata nessuno si collega.
  - Porta 11100 aperta nel firewall di Windows SOLO alla subnet dei PC docenti
    (Rete-Veyon.txt, voce SubnetDocenti).
  - Icona nella barra nascosta: gli alunni non vedono nulla.
  Si puo' lanciare da solo (VEYON-CARRELLO.bat) oppure da Installa-PC.ps1 / Aggiorna-PC.ps1.
.PARAMETER Dir
  Cartella con Veyon-Comune.ps1, la chiave pubblica e Rete-Veyon.txt (default: quella dello script).
.PARAMETER SoloInstalla
  Installa il Service e lo lascia CHIUSO (servizio disattivato, nessuna regola di firewall, nessuna chiave).
  E' anche quello che succede se la chiave pubblica non e' (ancora) nel pacchetto. La configurazione
  completa parte da sola (Installa-PC.ps1 -Aggiorna) quando nel pacchetto arriva veyon-docenti-pubblica.key.
.PARAMETER Simula
  Non modifica nulla.
#>
[CmdletBinding()]
param([string]$Dir, [switch]$Simula, [switch]$SoloInstalla)

if (-not $Dir) { $Dir = $PSScriptRoot }
. (Join-Path $Dir 'Veyon-Comune.ps1')
$script:VSimula = [bool]$Simula

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin -and -not $Simula) { Write-Host 'Serve eseguire come amministratore.' -ForegroundColor Red; exit 1 }

$rete = Get-ReteVeyon $Dir
$subnets = @($rete.SubnetDocenti -split '\s*,\s*' | Where-Object { $_ })
Write-VLog "Veyon Service: inizio (docenti: $($subnets -join ', '))"

$pub = Join-Path $Dir 'veyon-docenti-pubblica.key'
$chiusa = $SoloInstalla -or -not (Test-Path -LiteralPath $pub)

if (-not (Install-Veyon $Dir $false)) { exit 1 }
if ($Simula) {
    if ($chiusa) { Write-VLog '[SIMULAZIONE] Veyon Service installato e lasciato CHIUSO (servizio disattivato, nessuna regola, nessuna chiave)' }
    else { Write-VLog "[SIMULAZIONE] importerei la chiave pubblica, autenticazione a chiave, firewall 11100 solo da $($subnets -join ', ')" }
    exit 0
}

if ($chiusa) {
    # gia' configurato e aperto in precedenza: non lo richiudo
    if (Get-NetFirewallRule -Name 'Carrello-Veyon' -ErrorAction SilentlyContinue) { Write-VLog 'Veyon gia'' configurato: non lo modifico'; exit 0 }
    try {
        Set-VeyonConfig 'Authentication/Method' '1'                    # chiave, ma senza chiavi installate nessuno entra
        Set-VeyonConfig 'Network/FirewallExceptionEnabled' '0'
        Set-VeyonConfig 'Service/HideTrayIcon' '1'
        Stop-Service VeyonService -ErrorAction SilentlyContinue
        Set-Service VeyonService -StartupType Disabled -ErrorAction SilentlyContinue
        Remove-VeyonFirewallRules
        $ascolta = [bool](Get-NetTCPConnection -State Listen -LocalPort 11100 -ErrorAction SilentlyContinue)
        Write-VLog ("Veyon Service installato e CHIUSO (servizio disattivato, nessuna regola, porta 11100 in ascolto={0}). Si apre quando arriva la chiave." -f $ascolta)
    } catch { Write-VLog "Errore: $($_.Exception.Message)" 'ERRORE'; exit 1 }
    exit 0
}

try {
    Stop-Service VeyonService -ErrorAction SilentlyContinue
    $r = Invoke-VeyonCli authkeys import "$($script:VeyonChiave)/public" $pub
    if ($r.Code -ne 0) { Write-VLog "Import della chiave pubblica non riuscito: $($r.Output)" 'ERRORE'; exit 1 }

    Set-VeyonConfig 'Authentication/Method' '1'                    # 1 = chiave
    Set-VeyonConfig 'Network/VeyonServerPort' '11100'
    Set-VeyonConfig 'Network/FirewallExceptionEnabled' '0'         # il firewall lo gestiamo noi
    Set-VeyonConfig 'Service/HideTrayIcon' '1'
    Set-VeyonConfig 'Service/RemoteConnectionNotifications' '0'
    Set-VeyonConfig 'Service/FailedAuthenticationNotifications' '0'
    Set-VeyonConfig 'Service/Autostart' '1'

    Remove-VeyonFirewallRules
    Remove-NetFirewallRule -Name 'Carrello-Veyon' -ErrorAction SilentlyContinue
    New-NetFirewallRule -Name 'Carrello-Veyon' -DisplayName 'Veyon dai PC dei docenti (Carrello)' -Direction Inbound -Protocol TCP `
        -LocalPort 11100 -Action Allow -RemoteAddress $subnets -Profile Any | Out-Null

    Set-Service VeyonService -StartupType Automatic
    Start-Service VeyonService
    Start-Sleep -Seconds 3
    $ok = [bool](Get-NetTCPConnection -State Listen -LocalPort 11100 -ErrorAction SilentlyContinue)
    $m = (Invoke-VeyonCli config get Authentication/Method).Output
    Write-VLog ("Veyon Service attivo: porta 11100 in ascolto={0}, metodo={1}, chiavi: {2}" -f $ok, $m, ((Invoke-VeyonCli authkeys list).Output -replace '\s+', ' '))
    if (-not $ok) { exit 2 }
} catch {
    Write-VLog "Errore: $($_.Exception.Message)" 'ERRORE'
    exit 1
}
exit 0
