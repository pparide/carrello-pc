<#
.SYNOPSIS
  Configura un PC del carrello in un solo passaggio. Chiede SOLO il numero del
  carrello e il numero del PC. Windows 11 Home. Reversibile con -Annulla.

.DESCRIPTION
  Cosa fa, in ordine, senza altre domande:
    1. Backup dei file di tutti gli utenti (C:\Backup-Carrello e, se c'e' spazio, sulla chiavetta).
    2. Pulizia (file temporanei, cestino, TRIM).
    3. Account: AdminDocente (amministratore) e Studente (standard, accesso automatico).
       Gli altri amministratori vengono declassati e disattivati (mai cancellati).
       Le password sono lette da Impostazioni-scuola.txt (create al primo uso).
    4. Cartella C:\Lavori, sfondo con il numero del PC, blocchi leggeri per Studente,
       desktop pulito a ogni accesso (il contenuto va in C:\Backup-Carrello\Pulizie).
    5. Policy per Chrome (sempre in modalita' ospite, Google, predefinito) ed Edge, OneDrive spento, niente schermate di primo accesso.
    6. Gestione remota (SSH con chiave) per amministrare il PC da un altro computer.
    7. Wi-Fi: connessione automatica delle reti salvate.
    8. Rimozione di app e programmi non consentiti (vedi gli elenchi .txt).
    9. Nome del PC (C<carrello>-<numero>) e riavvio dopo 30 secondi.

.PARAMETER Carrello / NumeroPC
  Se omessi, vengono chiesti.
.PARAMETER Simula
  Non modifica nulla: scrive cosa farebbe (file Simulazione_<PC>.txt).
.PARAMETER Annulla
  Toglie blocchi, attivita' pianificata e accesso automatico.
.PARAMETER SenzaBackup / NoRiavvio / NoSoloConsentite / ConBloccoProgrammi
  Opzioni per prove e casi particolari.
.PARAMETER Logon
  Uso interno: lo lancia l'attivita' pianificata a ogni accesso.
.PARAMETER Aggiorna
  Uso interno: lo lancia Aggiorna-PC.ps1 (aggiornamento automatico). Riapplica la
  configurazione su un PC gia' installato: niente domande, backup, account, password,
  rinomina o riavvio.
#>
[CmdletBinding()]
param(
    [ValidateRange(1, 9)][int]$Carrello,
    [ValidateRange(1, 99)][int]$NumeroPC,
    [switch]$Simula,
    [switch]$Annulla,
    [switch]$SenzaBackup,
    [switch]$NoRiavvio,
    [switch]$NoSoloConsentite,
    [switch]$ConBloccoProgrammi,
    [switch]$Logon,
    [switch]$Aggiorna
)

$ErrorActionPreference = 'Continue'
$Versione    = '2.1'
$AdminName   = 'AdminDocente'
$StudentName = 'Studente'
$LavoriDir   = 'C:\Lavori'
$BackupDir   = 'C:\Backup-Carrello'
$Base        = Join-Path $env:ProgramData 'GestioneCarrello'
$LogFile     = Join-Path $Base 'log.txt'
$StateFile   = Join-Path $Base 'stato.json'
$ScriptCopy  = Join-Path $Base 'Installa-PC.ps1'
$WallFile    = Join-Path $Base 'sfondo.png'
$TaskbarXml  = Join-Path $Base 'TaskbarLayout.xml'
$TaskbarXmlAdmin = Join-Path $Base 'TaskbarLayoutAdmin.xml'
$TaskName    = 'Carrello-Logon'
$UpdTaskName = 'Carrello-Aggiorna'
$ClassTaskName = 'Carrello-Classe'
$NetTaskName = 'Carrello-Rete'
$UpdScript   = Join-Path $Base 'Aggiorna-PC.ps1'
$BuildFile   = Join-Path $Base 'build.txt'
$HiveTmp     = 'CarrelloTmp'
$SettingsFile = Join-Path $PSScriptRoot 'Impostazioni-scuola.txt'
$SimLog      = if ($PSScriptRoot) { Join-Path $PSScriptRoot ('Simulazione_{0}.txt' -f $env:COMPUTERNAME) } else { Join-Path $env:TEMP 'Simulazione.txt' }
if ($Simula) { try { Set-Content -Path $SimLog -Value '' -Encoding UTF8 } catch { $SimLog = Join-Path $env:TEMP 'Simulazione.txt' } }
$DefaultPubKey = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIR7jirPJgIXL4rdozfRkiihzEH+OI23wKSUxIbZvHWE carrello-mac'
$studentPw   = $null
$adminPw     = $null

# ======================================================== utilita'
# firma dell'autore, mostrata all'avvio e alla fine e salvata sul PC
$Firma = @('Installatore carrelli PC - realizzato da Paride Porpora', 'Primo Istituto Comprensivo di Mercato San Severino')
function Show-Banner {
    Write-Host ''
    Write-Host '==============================================================' -ForegroundColor Cyan
    Write-Host ('  {0}  (v{1})' -f $Firma[0], $Versione) -ForegroundColor Cyan
    Write-Host ('  {0}' -f $Firma[1]) -ForegroundColor Cyan
    Write-Host '==============================================================' -ForegroundColor Cyan
}
function Write-Log([string]$msg, [string]$level = 'INFO') {
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $level, $msg
    if (-not $Logon) { Write-Host $line }
    if ($Simula) {
        try { Add-Content -Path $SimLog -Value $line -Encoding UTF8 } catch { }
        return
    }
    try {
        if (-not (Test-Path $Base)) { New-Item -ItemType Directory -Path $Base -Force | Out-Null }
        Add-Content -Path $LogFile -Value $line -Encoding UTF8
    } catch { }
}

function Set-RegValue([string]$Root, [string]$Sub, [string]$Name, [string]$Type, $Value) {
    $full = "$Root\$Sub"
    if ($Simula) {
        $shown = if ($Name -like '*Password*') { '********' } else { $Value }
        Write-Log "[SIMULAZIONE] $full : $Name = $shown"
        return
    }
    try {
        if (-not (Test-Path -LiteralPath $full)) { New-Item -Path $full -Force | Out-Null }
        New-ItemProperty -LiteralPath $full -Name $Name -PropertyType $Type -Value $Value -Force -ErrorAction Stop | Out-Null
    } catch { Write-Log "Errore scrivendo $full : $Name : $($_.Exception.Message)" 'ERRORE' }
}
function Remove-RegValue([string]$Root, [string]$Sub, [string]$Name) {
    $full = "$Root\$Sub"
    if ($Simula) { Write-Log "[SIMULAZIONE] rimuoverei $full : $Name"; return }
    if (Test-Path -LiteralPath $full) { Remove-ItemProperty -LiteralPath $full -Name $Name -ErrorAction SilentlyContinue }
}
function Remove-RegKey([string]$Root, [string]$Sub) {
    $full = "$Root\$Sub"
    if ($Simula) { Write-Log "[SIMULAZIONE] rimuoverei la chiave $full"; return }
    if (Test-Path -LiteralPath $full) { Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction SilentlyContinue }
}

function Get-State {
    if (Test-Path $StateFile) { try { return (Get-Content $StateFile -Raw | ConvertFrom-Json) } catch { } }
    [pscustomobject]@{ Demoted = @() }
}
function Save-State($state) {
    if ($Simula) { return }
    $state | ConvertTo-Json -Depth 4 | Set-Content -Path $StateFile -Encoding UTF8
}
function New-RandomPassword([int]$len = 16) {
    $chars = 'abcdefghjkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789'
    -join (1..$len | ForEach-Object { $chars[(Get-Random -Maximum $chars.Length)] })
}
function Get-FolderBytes([string]$p) {
    if (-not (Test-Path -LiteralPath $p)) { return [int64]0 }
    $s = (Get-ChildItem -LiteralPath $p -Recurse -Force -File -Attributes '!ReparsePoint' -ErrorAction SilentlyContinue |
          Measure-Object -Property Length -Sum).Sum
    if ($s) { return [int64]$s } else { return [int64]0 }
}
function Initialize-BackupDir {
    if ($Simula) { return }
    if (-not (Test-Path $BackupDir)) { New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null }
    & icacls.exe $BackupDir /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
}
# sposta il contenuto di una cartella (es. Desktop) in C:\Backup-Carrello\Pulizie\<data>\ invece di cancellarlo
function Move-ToBackup([string]$path, [string]$label) {
    if ($Simula -or -not (Test-Path -LiteralPath $path)) { return }
    $items = @(Get-ChildItem -LiteralPath $path -Force -ErrorAction SilentlyContinue |
               Where-Object { $_.Name -ne 'desktop.ini' -and $_.Name -ne 'Lavori.lnk' -and $_.Name -ne 'COME USARE IL PC.txt' -and $_.Name -ne 'Cambia classe.lnk' })
    if ($items.Count -eq 0) { return }
    Initialize-BackupDir
    $dest = Join-Path $BackupDir ('Pulizie\{0}\{1}' -f (Get-Date -Format 'yyyyMMdd-HHmm'), $label)
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
    foreach ($i in $items) { Move-Item -LiteralPath $i.FullName -Destination $dest -Force -ErrorAction SilentlyContinue }
    $root = Join-Path $BackupDir 'Pulizie'
    Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.CreationTime -lt (Get-Date).AddDays(-30) } |
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
}
function Get-PatternList([string]$file) {
    if (-not (Test-Path -LiteralPath $file)) { return @() }
    @(Get-Content -LiteralPath $file | ForEach-Object { ($_ -replace '#.*$', '').Trim() } | Where-Object { $_ })
}
function Test-MatchAny([string]$text, [string[]]$patterns) {
    foreach ($p in $patterns) { if ($text -like $p) { return $true } }
    return $false
}

# impostazioni della scuola (password): create al primo uso, poi riusate su tutti i PC
function Get-Settings {
    $h = @{}
    if (Test-Path -LiteralPath $SettingsFile) {
        foreach ($l in (Get-Content -LiteralPath $SettingsFile)) {
            if ($l -match '^\s*([A-Za-z]+)\s*=\s*(.+?)\s*$') { $h[$Matches[1]] = $Matches[2] }
        }
    }
    $created = $false
    # password degli alunni: semplice (la usa l'accesso automatico); quella dell'amministratore: casuale e lunga
    if (-not $h['StudentPassword']) { $h['StudentPassword'] = 'studente'; $created = $true }
    if (-not $h['AdminPassword']) { $h['AdminPassword'] = if ($Simula) { 'simulazione' } else { New-RandomPassword 16 }; $created = $true }
    if ($created -and -not $Simula) {
        $text = "# Password della scuola, usate da Installa-PC.ps1 su TUTTI i PC dei carrelli.`r`n" +
                "# Conservale nel gestore di password e tieni questo file al sicuro (non lasciarlo sulla chiavetta in giro).`r`n" +
                "AdminPassword=$($h['AdminPassword'])`r`nStudentPassword=$($h['StudentPassword'])`r`n"
        try { Set-Content -LiteralPath $SettingsFile -Value $text -Encoding ascii }
        catch { $script:SettingsFile = Join-Path $env:TEMP 'Impostazioni-scuola.txt'; Set-Content -LiteralPath $script:SettingsFile -Value $text -Encoding ascii }
        Write-Host ''
        Write-Host "Ho creato il file $SettingsFile con le password dell'amministratore e di Studente." -ForegroundColor Yellow
        Write-Host 'Salvale nel gestore di password: servono per entrare come amministratore sui PC.' -ForegroundColor Yellow
    }
    return $h
}

# ======================================================== elenco impostazioni
$HKLM = 'HKLM:'

# --- impostazioni per l'account Studente (scritte nel suo registro)
$PolExp = 'Software\Microsoft\Windows\CurrentVersion\Policies\Explorer'
$PolSys = 'Software\Microsoft\Windows\CurrentVersion\Policies\System'
$PolAD  = 'Software\Microsoft\Windows\CurrentVersion\Policies\ActiveDesktop'
$CDM    = 'Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'

$blockedExe = 'powershell.exe', 'powershell_ise.exe', 'pwsh.exe', 'cmd.exe', 'regedit.exe',
              'WindowsTerminal.exe', 'wt.exe', 'wsl.exe', 'mmc.exe', 'msedge.exe'

$UserPolicies = New-Object System.Collections.Generic.List[object]
function Add-UP([string]$p, [string]$n, [string]$t, $v) { $UserPolicies.Add(@{ P = $p; N = $n; T = $t; V = $v }) }
Add-UP $PolExp 'NoControlPanel' 'DWord' 1
Add-UP $PolExp 'NoRun'          'DWord' 1
Add-UP $PolExp 'NoSetTaskbar'   'DWord' 1
Add-UP $PolExp 'DisallowRun'    'DWord' 1
$i = 1
foreach ($e in $blockedExe) { Add-UP "$PolExp\DisallowRun" "$i" 'String' $e; $i++ }
Add-UP $PolSys 'DisableRegistryTools' 'DWord' 1
Add-UP $PolSys 'DisableCMD'           'DWord' 2
Add-UP $PolSys 'DisableTaskMgr'       'DWord' 1
Add-UP $PolSys 'Wallpaper'            'String' $WallFile
Add-UP $PolSys 'WallpaperStyle'       'String' '10'
Add-UP $PolAD  'NoChangingWallPaper'  'DWord' 1
Add-UP 'Software\Policies\Microsoft\WindowsStore' 'RemoveWindowsStore' 'DWord' 1
# salvaschermo standard (vuoto, senza password, 10 minuti): l'alunno non lo puo' cambiare
$PolScr = 'Software\Policies\Microsoft\Windows\Control Panel\Desktop'
Add-UP $PolScr 'ScreenSaveActive'     'String' '1'
Add-UP $PolScr 'ScreenSaveTimeOut'    'String' '600'
Add-UP $PolScr 'SCRNSAVE.EXE'         'String' 'C:\Windows\System32\scrnsave.scr'
Add-UP $PolScr 'ScreenSaverIsSecure'  'String' '0'

$UserDefaults = New-Object System.Collections.Generic.List[object]
function Add-UD([string]$p, [string]$n, [string]$t, $v) { $UserDefaults.Add(@{ P = $p; N = $n; T = $t; V = $v }) }
Add-UD 'Control Panel\Desktop' 'Wallpaper'      'String' $WallFile
Add-UD 'Control Panel\Desktop' 'WallpaperStyle' 'String' '10'
Add-UD 'Control Panel\Desktop' 'TileWallpaper'  'String' '0'
Add-UD 'Software\Microsoft\Windows\CurrentVersion\UserProfileEngagement' 'ScoobeSystemSettingEnabled' 'DWord' 0
Add-UD 'Software\Microsoft\Windows\CurrentVersion\Privacy' 'PrivacyConsentStatus' 'DWord' 1
# barra delle applicazioni: Start e icone a sinistra; niente selettore desktop, Copilot, widget, chat
$AdvExp = 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
Add-UD $AdvExp 'TaskbarAl'          'DWord' 0
Add-UD $AdvExp 'ShowTaskViewButton' 'DWord' 0
Add-UD $AdvExp 'ShowCopilotButton'  'DWord' 0
Add-UD $AdvExp 'TaskbarMn'          'DWord' 0
Add-UD $AdvExp 'Start_IrisRecommendations' 'DWord' 0
Add-UD $AdvExp 'Start_AccountNotifications' 'DWord' 0
foreach ($n in 'SubscribedContent-338387Enabled', 'SubscribedContent-338388Enabled', 'SubscribedContent-338389Enabled',
               'SubscribedContent-353694Enabled', 'SubscribedContent-353696Enabled', 'SubscribedContent-310093Enabled',
               'SystemPaneSuggestionsEnabled', 'SilentInstalledAppsEnabled', 'OemPreInstalledAppsEnabled',
               'PreInstalledAppsEnabled', 'ContentDeliveryAllowed') { Add-UD $CDM $n 'DWord' 0 }

# --- impostazioni di sistema (HKLM)
$MachinePolicies = New-Object System.Collections.Generic.List[object]
function Add-MP([string]$p, [string]$n, [string]$t, $v) { $MachinePolicies.Add(@{ P = $p; N = $n; T = $t; V = $v }) }
Add-MP 'SOFTWARE\Policies\Microsoft\Windows\OneDrive' 'DisableFileSyncNGSC' 'DWord' 1
Add-MP 'SOFTWARE\Policies\Microsoft\Windows\OOBE' 'DisablePrivacyExperience' 'DWord' 1
Add-MP 'SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' 'EnableFirstLogonAnimation' 'DWord' 0
Add-MP 'SOFTWARE\Microsoft\WindowsUpdate\UX\Settings' 'ActiveHoursStart' 'DWord' 7
Add-MP 'SOFTWARE\Microsoft\WindowsUpdate\UX\Settings' 'ActiveHoursEnd' 'DWord' 19
Add-MP 'SOFTWARE\Microsoft\WindowsUpdate\UX\Settings' 'SmartActiveHoursState' 'DWord' 2
Add-MP 'SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' 'NoAutoRebootWithLoggedOnUsers' 'DWord' 1
# Windows Update sempre attivo e automatico (scarica e installa da solo), anche gli altri prodotti Microsoft (Office)
Add-MP 'SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' 'NoAutoUpdate' 'DWord' 0
Add-MP 'SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' 'AUOptions' 'DWord' 4
Add-MP 'SOFTWARE\Microsoft\WindowsUpdate\UX\Settings' 'AllowMUUpdateService' 'DWord' 1
# Delivery Optimization: i PC si scambiano gli aggiornamenti sulla rete locale (meno traffico verso Internet)
Add-MP 'SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization' 'DODownloadMode' 'DWord' 1
Add-MP 'SYSTEM\CurrentControlSet\Control\Session Manager\Power' 'HiberbootEnabled' 'DWord' 0
foreach ($b in 'SOFTWARE\Policies\Google\Chrome', 'SOFTWARE\Policies\Microsoft\Edge') {
    Add-MP $b 'PasswordManagerEnabled'       'DWord' 0
    Add-MP $b 'SavingBrowserHistoryDisabled' 'DWord' 1
    Add-MP $b 'BrowserSignin'                'DWord' 0
    Add-MP $b 'SyncDisabled'                 'DWord' 1
    Add-MP $b 'DefaultCookiesSetting'        'DWord' 4
    Add-MP $b 'AutofillAddressEnabled'       'DWord' 0
    Add-MP $b 'AutofillCreditCardEnabled'    'DWord' 0
    Add-MP $b 'DeveloperToolsAvailability'   'DWord' 2
    Add-MP "$b\ExtensionInstallBlocklist" '1' 'String' '*'
}
Add-MP 'SOFTWARE\Policies\Google\Chrome' 'BackgroundModeEnabled' 'DWord' 0
Add-MP 'SOFTWARE\Policies\Microsoft\Edge' 'BackgroundModeEnabled' 'DWord' 0
# Copilot spento; Edge non si reinstalla da solo
Add-MP 'SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot' 'DWord' 1
Add-MP 'SOFTWARE\Policies\Microsoft\EdgeUpdate' 'Install{56EB18F8-B008-4CBD-B6D2-8C97FE7E9062}' 'DWord' 0
Add-MP 'SOFTWARE\Microsoft\EdgeUpdate' 'DoNotUpdateToEdgeWithChromium' 'DWord' 1
Add-MP 'SOFTWARE\Policies\Microsoft\EdgeUpdate' 'CreateDesktopShortcutDefault' 'DWord' 0
# Chrome: sempre in modalita' ospite (alla chiusura cancella cronologia, cookie e dati), Google come motore di ricerca
$ChromeP = 'SOFTWARE\Policies\Google\Chrome'
Add-MP $ChromeP 'BrowserGuestModeEnabled'  'DWord' 1
Add-MP $ChromeP 'BrowserGuestModeEnforced' 'DWord' 1
Add-MP $ChromeP 'DefaultSearchProviderEnabled'   'DWord'  1
Add-MP $ChromeP 'DefaultSearchProviderName'      'String' 'Google'
Add-MP $ChromeP 'DefaultSearchProviderKeyword'   'String' 'google.com'
Add-MP $ChromeP 'DefaultSearchProviderSearchURL' 'String' 'https://www.google.com/search?q={searchTerms}'
Add-MP $ChromeP 'DefaultBrowserSettingEnabled'   'DWord'  1
Add-MP 'SOFTWARE\Policies\Microsoft\Edge' 'StartupBoostEnabled'   'DWord' 0
Add-MP 'SOFTWARE\Policies\Microsoft\Edge' 'HideFirstRunExperience' 'DWord' 1
Add-MP 'SOFTWARE\Policies\Microsoft\Edge' 'HubsSidebarEnabled'    'DWord' 0

# --- blocco rigido dei programmi (opzionale: blocca anche gli script dell'amministratore)
$SrpSub  = 'SOFTWARE\Policies\Microsoft\Windows\Safer\CodeIdentifiers'
$SrpDeny = [ordered]@{
    '{a1b2c3d4-0001-4000-8000-00000000c001}' = '%USERPROFILE%\AppData'
    '{a1b2c3d4-0001-4000-8000-00000000c002}' = '%USERPROFILE%\Downloads'
    '{a1b2c3d4-0001-4000-8000-00000000c003}' = '%USERPROFILE%\Desktop'
    '{a1b2c3d4-0001-4000-8000-00000000c004}' = $LavoriDir
}
$SrpAllow = [ordered]@{
    '{a1b2c3d4-0001-4000-8000-00000000c101}' = '%USERPROFILE%\AppData\Local\Microsoft\WindowsApps'
}

# componenti che la modalita' "solo consentite" non tocca mai
$StoreProtected = @('Microsoft.*', 'MicrosoftWindows.*', 'MicrosoftCorporationII.*', '*Runtime*', '*Extension*')
$ProgProtectedPublisher = @('Microsoft*', 'Intel*', 'Realtek*', 'NVIDIA*', 'Advanced Micro Devices*', 'AMD*', 'Synaptics*', 'Qualcomm*', 'MediaTek*', 'Dolby*')
$ProgProtectedName = @('Microsoft *', 'Windows *', '*Redistributable*', '*Runtime*', '*.NET*', '*Driver*', '*WebView2*', 'OpenSSH*')

# ======================================================== funzioni di lavoro
function Set-UserConfig([string]$root) {
    foreach ($p in $UserPolicies) { Set-RegValue $root $p.P $p.N $p.T $p.V }
    foreach ($p in $UserDefaults) { Set-RegValue $root $p.P $p.N $p.T $p.V }
}
function Remove-UserConfig([string]$root) {
    foreach ($p in $UserPolicies) { Remove-RegValue $root $p.P $p.N }
    Remove-RegKey $root "$PolExp\DisallowRun"
}

function Use-UserHive([string]$sid, [scriptblock]$action) {
    if (Test-Path "Registry::HKEY_USERS\$sid") { & $action "Registry::HKEY_USERS\$sid"; return $true }
    $prof = (Get-CimInstance Win32_UserProfile -Filter "SID='$sid'" -ErrorAction SilentlyContinue).LocalPath
    $dat  = if ($prof) { Join-Path $prof 'NTUSER.DAT' } else { $null }
    if (-not $dat -or -not (Test-Path -LiteralPath $dat)) { return $false }
    if ($Simula) { & $action "Registry::HKEY_USERS\$HiveTmp"; return $true }
    & reg.exe load "HKU\$HiveTmp" "$dat" | Out-Null
    try { & $action "Registry::HKEY_USERS\$HiveTmp" }
    finally {
        [gc]::Collect(); [gc]::WaitForPendingFinalizers(); Start-Sleep -Milliseconds 500
        & reg.exe unload "HKU\$HiveTmp" | Out-Null
    }
    return $true
}

function New-StudentProfile([string]$sid, [string]$userName = $StudentName) {
    if ($Simula) { Write-Log "[SIMULAZIONE] creerei il profilo di $userName"; return }
    try {
        Add-Type -Namespace Carrello -Name Profilo -MemberDefinition @'
[DllImport("userenv.dll", CharSet=CharSet.Unicode)]
public static extern int CreateProfile(string pszUserSid, string pszUserName, System.Text.StringBuilder pszProfilePath, uint cchProfilePath);
'@ -ErrorAction Stop
        $sb = New-Object System.Text.StringBuilder 260
        $hr = [Carrello.Profilo]::CreateProfile($sid, $userName, $sb, 260)
        Write-Log ("Creazione profilo di {0}: esito 0x{1:X}" -f $userName, $hr)
    } catch { Write-Log "Profilo non creato ora (verra' creato al primo accesso): $($_.Exception.Message)" 'AVVISO' }
}

# sfondo: una bella foto (la tua cartella Sfondi, oppure le foto di Windows) con il numero del PC in un angolo
function New-WallpaperImage([string]$path, [string]$label, [int]$cart) {
    if ($Simula) { Write-Log "[SIMULAZIONE] creerei lo sfondo con il numero $label"; return }
    try {
        Add-Type -AssemblyName System.Drawing
        $src = $null
        $dir = Join-Path $PSScriptRoot 'Sfondi'
        if (-not (Test-Path -LiteralPath $dir)) { $dir = Join-Path $Base 'Sfondi' }
        $mine = @(Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "carrello$cart.*" })
        $all  = @(Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -match '^\.(jpg|jpeg|png|bmp)$' } | Sort-Object Name)
        if ($mine.Count -gt 0) { $src = $mine[0].FullName }
        elseif ($all.Count -gt 0) { $src = $all[($cart - 1) % $all.Count].FullName }
        else {
            $wp = 'C:\Windows\Web\Wallpaper'
            # foto di natura di Windows (laghi e montagne all'alba); un carrello = una foto
            $opts = @('ThemeC\img29.jpg', 'ThemeC\img28.jpg', 'ThemeC\img30.jpg', 'ThemeC\img31.jpg', '..\Screen\img102.jpg') |
                    ForEach-Object { Join-Path $wp $_ } | Where-Object { Test-Path -LiteralPath $_ }
            if (@($opts).Count -gt 0) { $src = @($opts)[($cart - 1) % @($opts).Count] }
        }
        $w = 1920; $h = 1080
        $bmp = New-Object System.Drawing.Bitmap $w, $h
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.SmoothingMode = 'AntiAlias'; $g.InterpolationMode = 'HighQualityBicubic'; $g.TextRenderingHint = 'AntiAliasGridFit'
        if ($src) {
            $img = [System.Drawing.Image]::FromFile($src)
            $scale = [math]::Max($w / $img.Width, $h / $img.Height)
            $dw = [int]($img.Width * $scale); $dh = [int]($img.Height * $scale)
            $g.DrawImage($img, [int](($w - $dw) / 2), [int](($h - $dh) / 2), $dw, $dh)
            $img.Dispose()
        } else {
            $rect = New-Object System.Drawing.Rectangle 0, 0, $w, $h
            $br = New-Object System.Drawing.Drawing2D.LinearGradientBrush($rect, [System.Drawing.Color]::FromArgb(255, 16, 42, 96), [System.Drawing.Color]::FromArgb(255, 40, 100, 170), [single]45)
            $g.FillRectangle($br, $rect)
        }
        # etichetta in alto a destra, senza rettangolo: testo semitrasparente con una leggera ombra
        if ($label -match '^C(\d+)-(\d+)$') { $label = 'PC {0} del Carrello {1}' -f [int]$Matches[2], [int]$Matches[1] }
        $font = New-Object System.Drawing.Font('Segoe UI Semibold', 54, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)
        $size = $g.MeasureString($label, $font)
        $tx = $w - $size.Width - 50; $ty = 36
        $shadow = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(110, 0, 0, 0))
        $white  = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(205, 255, 255, 255))
        $g.DrawString($label, $font, $shadow, [single]($tx + 3), [single]($ty + 3))
        $g.DrawString($label, $font, $white,  [single]$tx,        [single]$ty)
        $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
        $g.Dispose(); $bmp.Dispose()
        Write-Log ("Sfondo creato con il numero {0} (immagine: {1})" -f $label, $(if ($src) { Split-Path $src -Leaf } else { 'sfumatura' }))
    } catch { Write-Log "Sfondo non creato: $($_.Exception.Message)" 'AVVISO' }
}

# GeoGebra Classic 6 (versione portatile ufficiale, nella cartella Installer): copiata in Program Files con il collegamento nel menu Start
function Install-GeoGebra {
    $sm = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs'
    if (Get-ChildItem -LiteralPath $sm -Recurse -Filter 'GeoGebra*.lnk' -ErrorAction SilentlyContinue | Select-Object -First 1) { Write-Log 'GeoGebra gia'' presente'; return }
    $zip = Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'Installer') -Filter 'GeoGebra*.zip' -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $zip) { Write-Log 'GeoGebra non installato: manca il file zip nella cartella Installer' 'AVVISO'; return }
    if ($Simula) { Write-Log "[SIMULAZIONE] installerei GeoGebra da $($zip.Name)"; return }
    try {
        $dest = Join-Path $env:ProgramFiles 'GeoGebra Classic 6'
        if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Recurse -Force -ErrorAction SilentlyContinue }
        Expand-Archive -LiteralPath $zip.FullName -DestinationPath $dest -Force
        $exe = Get-ChildItem -LiteralPath $dest -Recurse -Filter 'GeoGebra*.exe' -ErrorAction SilentlyContinue | Sort-Object Length -Descending | Select-Object -First 1
        if (-not $exe) { Write-Log 'GeoGebra: programma non trovato nel file zip' 'AVVISO'; return }
        $ws  = New-Object -ComObject WScript.Shell
        $lnk = $ws.CreateShortcut((Join-Path $sm 'GeoGebra Classic 6.lnk'))
        $lnk.TargetPath = $exe.FullName
        $lnk.WorkingDirectory = $exe.DirectoryName
        $lnk.Save()
        Write-Log ("GeoGebra installato in {0}" -f $exe.DirectoryName)
    } catch { Write-Log "GeoGebra non installato: $($_.Exception.Message)" 'AVVISO' }
}

# Chrome (modalita' ospite): senza queste opzioni a ogni apertura chiede di scegliere il motore di ricerca
function Set-ChromeShortcutArgs {
    if ($Simula) { Write-Log '[SIMULAZIONE] metterei le opzioni nel collegamento di Chrome'; return }
    $chromeArgs = '--disable-search-engine-choice-screen --no-first-run --no-default-browser-check'
    try {
        $ws = New-Object -ComObject WScript.Shell
        $targets = @(Get-ChildItem (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs') -Recurse -Filter 'Google Chrome.lnk' -ErrorAction SilentlyContinue)
        $targets += @(Get-ChildItem 'C:\Users\Studente' -Recurse -Filter 'Google Chrome.lnk' -Force -ErrorAction SilentlyContinue | Where-Object { $_.FullName -like '*\User Pinned\TaskBar\*' -or $_.FullName -like '*\Desktop\*' })
        foreach ($t in $targets) {
            $l = $ws.CreateShortcut($t.FullName)
            if ($l.Arguments -notlike '*disable-search-engine-choice-screen*') { $l.Arguments = $chromeArgs; $l.Save() }
        }
        Write-Log ("Chrome: opzioni di avvio impostate in {0} collegamenti" -f $targets.Count)
    } catch { Write-Log "Opzioni di Chrome non impostate: $($_.Exception.Message)" 'AVVISO' }
}

# barra delle applicazioni: Word, Excel, GeoGebra, Chrome, Calcolatrice, Scratch (solo quelli installati)
function New-TaskbarLayout([string]$Kind = 'Studente') {
    Set-ChromeShortcutArgs
    if ($Simula) { Write-Log '[SIMULAZIONE] creerei il layout della barra delle applicazioni'; return }
    $sm = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs'
    $pins = New-Object System.Collections.Generic.List[string]
    $startPins = New-Object System.Collections.Generic.List[object]
    $patterns = if ($Kind -eq 'Admin') { @('#EXPLORER#', 'Google Chrome.lnk', 'Word.lnk', 'Excel.lnk', '#POWERSHELL#', '#SETTINGS#') }
                else { @('Word.lnk', 'Excel.lnk', 'PowerPoint.lnk', 'GeoGebra*.lnk', 'Google Chrome.lnk', '#CALC#', 'Scratch*.lnk') }
    foreach ($pat in $patterns) {
        if ($pat -eq '#EXPLORER#') {
            $pins.Add('        <taskbar:DesktopApp DesktopApplicationID="Microsoft.Windows.Explorer" />')
            $startPins.Add('{"desktopAppId":"Microsoft.Windows.Explorer"}')
            continue
        }
        if ($pat -eq '#POWERSHELL#') {
            # il collegamento di PowerShell e' per utente: se ne crea uno nostro
            $psl = Join-Path $Base 'Windows PowerShell.lnk'
            try {
                $w = New-Object -ComObject WScript.Shell
                $l = $w.CreateShortcut($psl)
                $l.TargetPath = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
                $l.IconLocation = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe,0"
                $l.Save()
                $pins.Add(('        <taskbar:DesktopApp DesktopApplicationLinkPath="{0}" />' -f $psl))
                $startPins.Add('{"desktopAppLink":' + (ConvertTo-Json -InputObject $psl.Replace($env:ProgramData, '%ALLUSERSPROFILE%') -Compress) + '}')
            } catch { Write-Log "Collegamento di PowerShell non creato: $($_.Exception.Message)" 'AVVISO' }
            continue
        }
        if ($pat -eq '#SETTINGS#') {
            $pins.Add('        <taskbar:UWA AppUserModelID="windows.immersivecontrolpanel_cw5n1h2txyewy!microsoft.windows.immersivecontrolpanel" />')
            $startPins.Add('{"packagedAppId":"windows.immersivecontrolpanel_cw5n1h2txyewy!microsoft.windows.immersivecontrolpanel"}')
            continue
        }
        if ($pat -eq '#CALC#') {
            if (Get-AppxPackage -AllUsers -Name 'Microsoft.WindowsCalculator' -ErrorAction SilentlyContinue) {
                $pins.Add('        <taskbar:UWA AppUserModelID="Microsoft.WindowsCalculator_8wekyb3d8bbwe!App" />')
                $startPins.Add('{"packagedAppId":' + (ConvertTo-Json -InputObject 'Microsoft.WindowsCalculator_8wekyb3d8bbwe!App' -Compress) + '}')
            }
            continue
        }
        $f = Get-ChildItem -LiteralPath $sm -Recurse -Filter $pat -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($f) {
            $pins.Add(('        <taskbar:DesktopApp DesktopApplicationLinkPath="{0}" />' -f $f.FullName))
            $startPins.Add('{"desktopAppLink":' + (ConvertTo-Json -InputObject $f.FullName.Replace($env:ProgramData, '%ALLUSERSPROFILE%') -Compress) + '}')
        }
        else { Write-Log "Barra: collegamento non trovato per $pat (non viene aggiunto)" 'AVVISO' }
    }
    $lines = @(
        '<?xml version="1.0" encoding="utf-8"?>',
        '<LayoutModificationTemplate xmlns="http://schemas.microsoft.com/Start/2014/LayoutModification" xmlns:defaultlayout="http://schemas.microsoft.com/Start/2014/FullDefaultLayout" xmlns:start="http://schemas.microsoft.com/Start/2014/StartLayout" xmlns:taskbar="http://schemas.microsoft.com/Start/2014/TaskbarLayout" Version="1">',
        '  <CustomTaskbarLayoutCollection PinListPlacement="Replace">',
        '    <defaultlayout:TaskbarLayout>',
        '      <taskbar:TaskbarPinList>') + @($pins) + @(
        '      </taskbar:TaskbarPinList>',
        '    </defaultlayout:TaskbarLayout>',
        '  </CustomTaskbarLayoutCollection>',
        '</LayoutModificationTemplate>')
    $xmlOut = if ($Kind -eq 'Admin') { $TaskbarXmlAdmin } else { $TaskbarXml }
    Set-Content -LiteralPath $xmlOut -Value ($lines -join "`r`n") -Encoding UTF8
    # JSON scritto a mano: ConvertTo-Json di Windows PowerShell 5.1 si ferma con questo elenco
    $script:StartPinsJson = '{"pinnedList":[' + (($startPins.ToArray()) -join ',') + ']}'
    Write-Log ("Layout della barra e di Start ({0}) creato: {1} icone" -f $Kind, $pins.Count)
}

# il layout di Start e della barra si applica al PRIMO accesso di un profilo nuovo, partendo dal profilo Default
function Set-DefaultLayout([string]$xml = $TaskbarXml, [bool]$ConStart = $true) {
    if ($Simula) { Write-Log '[SIMULAZIONE] metterei il layout di Start e barra nel profilo Default'; return }
    try {
        $shell = 'C:\Users\Default\AppData\Local\Microsoft\Windows\Shell'
        New-Item -ItemType Directory -Path $shell -Force | Out-Null
        Copy-Item -LiteralPath $xml -Destination (Join-Path $shell 'LayoutModification.xml') -Force
        # l'elenco di Start (json) lo usa solo l'amministratore: per Studente un json fa comparire i riquadri promossi da Windows (WhatsApp, Xbox, Solitario...)
        if ($ConStart -and $script:StartPinsJson) { Set-Content -LiteralPath (Join-Path $shell 'LayoutModification.json') -Value $script:StartPinsJson -Encoding UTF8 }
        else { Remove-Item -LiteralPath (Join-Path $shell 'LayoutModification.json') -Force -ErrorAction SilentlyContinue }
    } catch { Write-Log "Layout nel profilo Default non scritto: $($_.Exception.Message)" 'AVVISO' }
}
function Clear-DefaultLayout {
    if ($Simula) { return }
    $shell = 'C:\Users\Default\AppData\Local\Microsoft\Windows\Shell'
    Remove-Item -LiteralPath (Join-Path $shell 'LayoutModification.xml') -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $shell 'LayoutModification.json') -Force -ErrorAction SilentlyContinue
}

# Chrome come browser predefinito (associazioni predefinite di Windows, riapplicate a ogni accesso)
function Set-DefaultBrowser {
    $xmlPath = Join-Path $Base 'AssociazioniPredefinite.xml'
    if ($Simula) { Write-Log '[SIMULAZIONE] imposterei Chrome come browser predefinito'; return }
    try {
        $x = @('<?xml version="1.0" encoding="UTF-8"?>', '<DefaultAssociations>')
        foreach ($a in '.htm', '.html', 'http', 'https') { $x += ('  <Association Identifier="{0}" ProgId="ChromeHTML" ApplicationName="Google Chrome" />' -f $a) }
        $x += '</DefaultAssociations>'
        Set-Content -LiteralPath $xmlPath -Value ($x -join "`r`n") -Encoding UTF8
        Set-RegValue $HKLM 'SOFTWARE\Policies\Microsoft\Windows\System' 'DefaultAssociationsConfiguration' 'String' $xmlPath
        & dism.exe /Online /Import-DefaultAppAssociations:"$xmlPath" | Out-Null
        Write-Log 'Chrome impostato come browser predefinito (dal prossimo accesso)'
    } catch { Write-Log "Browser predefinito non impostato: $($_.Exception.Message)" 'AVVISO' }
}
# amministratore: stesso aspetto (Start a sinistra, niente widget/Copilot/suggerimenti, sfondo con il numero) + impostazioni utili a chi gestisce il PC
function Set-AdminConfig([string]$root) {
    foreach ($p in $UserDefaults) { Set-RegValue $root $p.P $p.N $p.T $p.V }
    $adv = 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
    Set-RegValue $root $adv 'HideFileExt'     'DWord' 0   # mostra le estensioni dei file
    Set-RegValue $root $adv 'Hidden'          'DWord' 1   # mostra file e cartelle nascosti
    Set-RegValue $root $adv 'LaunchTo'        'DWord' 1   # Esplora file si apre su "Questo PC"
    Set-RegValue $root $adv 'ShowStatusBar'   'DWord' 1
    Set-RegValue $root $adv 'DisablePreviewDesktop' 'DWord' 0
    Set-RegValue $root 'Software\Microsoft\Windows\CurrentVersion\Explorer' 'ShowFrequent' 'DWord' 0
    Set-RegValue $root 'Software\Microsoft\Windows\CurrentVersion\Explorer' 'ShowRecent'   'DWord' 0
    Set-RegValue $root 'Software\Microsoft\Windows\CurrentVersion\Search' 'SearchboxTaskbarMode' 'DWord' 1
}
# profilo dell'amministratore GIA' esistente: barra e Start si rifanno con il layout dell'amministratore (una volta sola)
function Reset-AdminShell([string]$sid) {
    if ($Simula) { Write-Log "[SIMULAZIONE] rifarei barra e Start dell'amministratore"; return }
    try {
        $prof = (Get-CimInstance Win32_UserProfile -ErrorAction SilentlyContinue | Where-Object { $_.SID -eq $sid }).LocalPath
        if (-not $prof) { return }
        $mark = $false
        [void](Use-UserHive $sid { param($root) if ((Get-ItemProperty -Path "$root\Software\Carrello" -Name 'LayoutAdmin' -ErrorAction SilentlyContinue).LayoutAdmin -eq '1') { $script:markFound = $true } })
        if ($script:markFound) { return }
        $sh = Join-Path $prof 'AppData\Local\Microsoft\Windows\Shell'
        New-Item -ItemType Directory -Path $sh -Force | Out-Null
        Copy-Item -LiteralPath $TaskbarXmlAdmin -Destination (Join-Path $sh 'LayoutModification.xml') -Force
        if ($script:AdminPinsJson) { Set-Content -LiteralPath (Join-Path $sh 'LayoutModification.json') -Value $script:AdminPinsJson -Encoding UTF8 }
        Remove-Item -LiteralPath (Join-Path $prof 'AppData\Local\Packages\Microsoft.Windows.StartMenuExperienceHost_cw5n1h2txyewy\LocalState\start2.bin') -Force -ErrorAction SilentlyContinue
        [void](Use-UserHive $sid { param($root)
            Remove-Item -Path "$root\Software\Microsoft\Windows\CurrentVersion\Explorer\Taskband" -Recurse -Force -ErrorAction SilentlyContinue
            New-Item -Path "$root\Software\Carrello" -Force | Out-Null
            New-ItemProperty -Path "$root\Software\Carrello" -Name 'LayoutAdmin' -PropertyType String -Value '1' -Force | Out-Null })
        if ($env:USERNAME -eq $AdminName) {
            Stop-Process -Name StartMenuExperienceHost -Force -ErrorAction SilentlyContinue
            Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue   # si riavvia da solo
        }
        Write-Log "Barra e Start dell'amministratore rifatti"
    } catch { Write-Log "Barra dell'amministratore non rifatta: $($_.Exception.Message)" 'AVVISO' }
}
function Set-MachineConfig {
    foreach ($p in $MachinePolicies) { Set-RegValue $HKLM $p.P $p.N $p.T $p.V }
    Set-DefaultBrowser
}
# alimentazione: coperchio chiuso o tasto di accensione = arresto (niente sospensione che scarica la batteria nel carrello)
function Set-PowerConfig {
    if ($Simula) { Write-Log '[SIMULAZIONE] imposterei coperchio/tasto = arresto, ibernazione a batteria, batteria critica = iberna'; return }
    try {
        foreach ($m in 'ac', 'dc') {
            & powercfg.exe "/set${m}valueindex" SCHEME_CURRENT SUB_BUTTONS LIDACTION 3 | Out-Null
            & powercfg.exe "/set${m}valueindex" SCHEME_CURRENT SUB_BUTTONS PBUTTONACTION 3 | Out-Null
            & powercfg.exe "/set${m}valueindex" SCHEME_CURRENT SUB_SLEEP STANDBYIDLE 0 | Out-Null
        }
        & powercfg.exe /setacvalueindex SCHEME_CURRENT SUB_SLEEP HIBERNATEIDLE 0 | Out-Null
        & powercfg.exe /setdcvalueindex SCHEME_CURRENT SUB_SLEEP HIBERNATEIDLE 1800 | Out-Null
        & powercfg.exe /setdcvalueindex SCHEME_CURRENT SUB_BATTERY BATACTIONCRIT 2 | Out-Null
        & powercfg.exe /setactive SCHEME_CURRENT | Out-Null
        Write-Log 'Alimentazione: coperchio e tasto = arresto; a batteria ibernazione dopo 30 minuti'
    } catch { Write-Log "Alimentazione non impostata: $($_.Exception.Message)" 'AVVISO' }
}
function Remove-MachineConfig {
    Remove-RegValue $HKLM 'SOFTWARE\Policies\Microsoft\Windows\System' 'DefaultAssociationsConfiguration'
    foreach ($p in $MachinePolicies) {
        if ($p.P -like 'SOFTWARE\Microsoft\*' -or $p.P -like 'SYSTEM\*') { continue }
        Remove-RegValue $HKLM $p.P $p.N
    }
}

function Set-Autologon {
    $wl = 'SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    Set-RegValue $HKLM $wl 'AutoAdminLogon'    'String' '1'
    Set-RegValue $HKLM $wl 'DefaultUserName'   'String' $StudentName
    $dom = if ($newName) { $newName } else { $env:COMPUTERNAME }
    Set-RegValue $HKLM $wl 'DefaultDomainName' 'String' $dom
    if ($studentPw) { Set-RegValue $HKLM $wl 'DefaultPassword' 'String' $studentPw }
    Remove-RegValue $HKLM $wl 'AutoLogonCount'
    Set-RegValue $HKLM 'SOFTWARE\Microsoft\Windows NT\CurrentVersion\PasswordLess\Device' 'DevicePasswordLessBuildVersion' 'DWord' 0
}
function Remove-Autologon {
    $wl = 'SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    Set-RegValue $HKLM $wl 'AutoAdminLogon' 'String' '0'
    Remove-RegValue $HKLM $wl 'DefaultPassword'
}

function Set-Srp {
    Set-RegValue $HKLM $SrpSub 'DefaultLevel'        'DWord' 262144
    Set-RegValue $HKLM $SrpSub 'TransparentEnabled'  'DWord' 1
    Set-RegValue $HKLM $SrpSub 'PolicyScope'         'DWord' 1
    Set-RegValue $HKLM $SrpSub 'AuthenticodeEnabled' 'DWord' 0
    $types = 'ADE', 'ADP', 'BAS', 'BAT', 'CHM', 'CMD', 'COM', 'CPL', 'CRT', 'EXE', 'HLP', 'HTA', 'INF', 'INS', 'ISP',
             'MDB', 'MDE', 'MSC', 'MSI', 'MSP', 'MST', 'OCX', 'PCD', 'PIF', 'REG', 'SCR', 'SHS', 'VB', 'WSC'
    Set-RegValue $HKLM $SrpSub 'ExecutableTypes' 'MultiString' ([string[]]$types)
    foreach ($k in $SrpDeny.Keys) {
        Set-RegValue $HKLM "$SrpSub\0\Paths\$k" 'ItemData'  'ExpandString' $SrpDeny[$k]
        Set-RegValue $HKLM "$SrpSub\0\Paths\$k" 'SaferFlags' 'DWord' 0
    }
    foreach ($k in $SrpAllow.Keys) {
        Set-RegValue $HKLM "$SrpSub\262144\Paths\$k" 'ItemData'  'ExpandString' $SrpAllow[$k]
        Set-RegValue $HKLM "$SrpSub\262144\Paths\$k" 'SaferFlags' 'DWord' 0
    }
}
function Remove-Srp { Remove-RegKey $HKLM $SrpSub }

function Set-LogonTask {
    if ($Simula) { Write-Log "[SIMULAZIONE] registrerei l'attivita' $TaskName"; return }
    $arg = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Logon' -f $ScriptCopy
    $action    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arg
    $trigger   = New-ScheduledTaskTrigger -AtLogOn
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings  = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 5) -StartWhenAvailable
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
}
function Set-UpdateTask {
    if ($Simula) { Write-Log "[SIMULAZIONE] registrerei l'attivita' $UpdTaskName"; return }
    try {
        $arg = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $UpdScript
        $action    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arg
        $t1 = New-ScheduledTaskTrigger -AtStartup
        $t1.Delay = 'PT3M'
        # ogni giorno alle 8:00 e poi ogni 3 ore finche' il PC e' acceso (la sera i PC sono spenti nei carrelli)
        $t2 = New-ScheduledTaskTrigger -Daily -At '08:00'
        $t2.Repetition = (New-ScheduledTaskTrigger -Once -At '08:00' -RepetitionInterval (New-TimeSpan -Hours 3) -RepetitionDuration (New-TimeSpan -Hours 10)).Repetition
        $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        $settings  = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 30) -StartWhenAvailable -RunOnlyIfNetworkAvailable `
                        -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 10) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
        Register-ScheduledTask -TaskName $UpdTaskName -Action $action -Trigger @($t1, $t2) -Principal $principal -Settings $settings -Force | Out-Null
        Write-Log "Attivita' $UpdTaskName registrata (all'avvio e ogni giorno)"
    } catch { Write-Log "Attivita' $UpdTaskName non registrata: $($_.Exception.Message)" 'AVVISO' }
}
function Remove-UpdateTask {
    if ($Simula) { Write-Log "[SIMULAZIONE] toglierei l'attivita' $UpdTaskName"; return }
    Unregister-ScheduledTask -TaskName $UpdTaskName -Confirm:$false -ErrorAction SilentlyContinue
}
# scelta della classe: attivita' a richiesta, eseguita come Studente (la avvia l'attivita' di accesso e il collegamento "Cambia classe")
function Set-ClassTask {
    if ($Simula) { Write-Log "[SIMULAZIONE] registrerei l'attivita' $ClassTaskName"; return }
    try {
        $arg = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Classe' -f (Join-Path $Base 'Lavori.ps1')
        $action    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arg
        $principal = New-ScheduledTaskPrincipal -UserId "$env:COMPUTERNAME\$StudentName" -LogonType Interactive -RunLevel Limited
        $settings  = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 30) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
        Register-ScheduledTask -TaskName $ClassTaskName -Action $action -Principal $principal -Settings $settings -Force | Out-Null
        Write-Log "Attivita' $ClassTaskName registrata"
    } catch { Write-Log "Attivita' $ClassTaskName non registrata: $($_.Exception.Message)" 'AVVISO' }
}
# i PC dello stesso carrello si scambiano la classe scelta (UDP 47010 solo sulla rete locale): attivita' sempre accesa come SYSTEM
function Set-NetTask {
    if ($Simula) { Write-Log "[SIMULAZIONE] registrerei l'attivita' $NetTaskName e la regola del firewall UDP 47010"; return }
    try {
        Remove-NetFirewallRule -Name 'Carrello-Classi-UDP' -ErrorAction SilentlyContinue
        New-NetFirewallRule -Name 'Carrello-Classi-UDP' -DisplayName 'Scambio classi carrello (rete locale)' -Direction Inbound -Protocol UDP -LocalPort 47010 -Action Allow -RemoteAddress LocalSubnet -Profile Any | Out-Null
        if ($Aggiorna -and (Get-ScheduledTask -TaskName $NetTaskName -ErrorAction SilentlyContinue)) { return }
        $arg = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Ascolta' -f (Join-Path $Base 'Lavori.ps1')
        $action    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arg
        $trigger   = New-ScheduledTaskTrigger -AtStartup
        $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        $settings  = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -StartWhenAvailable
        Register-ScheduledTask -TaskName $NetTaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
        Start-ScheduledTask -TaskName $NetTaskName -ErrorAction SilentlyContinue
        Write-Log "Attivita' $NetTaskName registrata (scambio delle classi nel carrello)"
    } catch { Write-Log "Attivita' $NetTaskName non registrata: $($_.Exception.Message)" 'AVVISO' }
}
function Remove-LogonTask {
    if ($Simula) { Write-Log "[SIMULAZIONE] toglierei l'attivita' $TaskName"; return }
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
}
function Protect-BaseFolder {
    if ($Simula) { return }
    & icacls.exe $Base /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)RX' | Out-Null
}

# gestione remota: server SSH con accesso solo con chiave
function Enable-RemoteAccess {
    if ($Simula) { Write-Log '[SIMULAZIONE] abiliterei la gestione remota (SSH con chiave)'; return }
    try {
        if (-not (Get-Service -Name sshd -ErrorAction SilentlyContinue)) {
            $msi = Get-ChildItem -LiteralPath $PSScriptRoot -Filter 'OpenSSH-Win64*.msi' -ErrorAction SilentlyContinue | Select-Object -First 1
            if (-not $msi) { Write-Log 'Manca il pacchetto OpenSSH-Win64*.msi nella cartella dello script: gestione remota non installata' 'AVVISO'; return }
            $p = Start-Process -FilePath 'msiexec.exe' -ArgumentList ('/i "{0}" /qn /norestart' -f $msi.FullName) -Wait -PassThru
            Write-Log ("OpenSSH installato dal pacchetto locale (codice {0})" -f $p.ExitCode)
        }
        if (-not (Get-Service -Name sshd -ErrorAction SilentlyContinue)) { Write-Log 'OpenSSH non installato: gestione remota saltata' 'AVVISO'; return }

        $cfg = Join-Path $env:ProgramData 'ssh\sshd_config'
        if (-not (Test-Path $cfg)) {
            Set-Service -Name sshd -StartupType Automatic
            Start-Service sshd
            Start-Sleep -Seconds 3
            Stop-Service sshd -ErrorAction SilentlyContinue
            if (-not (Test-Path $cfg)) {
                $def = Join-Path $env:ProgramFiles 'OpenSSH\sshd_config_default'
                if (Test-Path $def) { New-Item -ItemType Directory -Path (Split-Path $cfg) -Force | Out-Null; Copy-Item -LiteralPath $def -Destination $cfg }
            }
        }
        $needRestart = $false
        if (Test-Path $cfg) {
            $text = Get-Content -LiteralPath $cfg -Raw
            if ($text -notmatch 'Carrello-gestione') {
                $head = "# Carrello-gestione`r`nPasswordAuthentication no`r`nPubkeyAuthentication yes`r`n"
                Set-Content -LiteralPath $cfg -Value ($head + $text) -Encoding ascii
                $needRestart = $true
            }
        }
        $keyText = $DefaultPubKey
        $kf = Join-Path $PSScriptRoot 'chiave-mac.pub'
        if (Test-Path -LiteralPath $kf) { $keyText = (Get-Content -LiteralPath $kf -Raw).Trim() }
        $keyFile = Join-Path $env:ProgramData 'ssh\administrators_authorized_keys'
        $current = if (Test-Path $keyFile) { (Get-Content -LiteralPath $keyFile -Raw).Trim() } else { '' }
        if ($current -ne $keyText) { Set-Content -LiteralPath $keyFile -Value $keyText -Encoding ascii }
        & icacls.exe $keyFile /inheritance:r /grant:r '*S-1-5-32-544:F' '*S-1-5-18:F' | Out-Null

        New-Item -Path 'HKLM:\SOFTWARE\OpenSSH' -Force | Out-Null
        New-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name 'DefaultShell' -PropertyType String -Force -Value 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' | Out-Null

        Get-NetFirewallRule -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like '*OpenSSH*' -and $_.Name -ne 'Carrello-SSH' -and $_.Direction -eq 'Inbound' } | Disable-NetFirewallRule
        Remove-NetFirewallRule -Name 'Carrello-SSH' -ErrorAction SilentlyContinue
        New-NetFirewallRule -Name 'Carrello-SSH' -DisplayName 'SSH dalla rete locale (Carrello)' -Direction Inbound -Protocol TCP -LocalPort 22 -Action Allow -RemoteAddress LocalSubnet -Profile Any | Out-Null

        Set-Service -Name sshd -StartupType Automatic
        $svc = Get-Service sshd
        if ($svc.Status -ne 'Running') { Start-Service sshd }
        elseif ($needRestart) { Restart-Service sshd }
        Write-Log 'Gestione remota (SSH con chiave) attiva'
    } catch { Write-Log "Gestione remota non configurata: $($_.Exception.Message)" 'AVVISO' }
}

# Wi-Fi: connessione automatica per tutte le reti salvate
function Set-WifiAuto {
    if ($Simula) { Write-Log '[SIMULAZIONE] imposterei la connessione automatica delle reti Wi-Fi salvate'; return }
    $names = @()
    foreach ($l in (netsh wlan show profiles 2>$null)) {
        if ($l -match '(?i)profil' -and $l -match ':\s*(.+?)\s*$') { $names += $Matches[1] }
    }
    foreach ($n in ($names | Select-Object -Unique)) {
        & netsh wlan set profileparameter name="$n" connectionmode=auto | Out-Null
        Write-Log "Wi-Fi: connessione automatica per la rete $n"
    }
}

# rete della scuola: se c'e' il file Impostazioni-Wifi.xml (profilo esportato, con la password: resta FUORI da GitHub) lo importa e gli da' la priorita'
function Set-SchoolWifi {
    $f = Join-Path $PSScriptRoot 'Impostazioni-Wifi.xml'
    if (-not (Test-Path -LiteralPath $f)) { if (-not $Aggiorna) { Write-Log 'Wi-Fi della scuola: file Impostazioni-Wifi.xml non trovato (la rete va collegata a mano)' 'AVVISO' }; return }
    if ($Simula) { Write-Log '[SIMULAZIONE] importerei il profilo Wi-Fi della scuola con priorita'' massima'; return }
    try {
        $ssid = ([xml](Get-Content -LiteralPath $f -Raw)).WLANProfile.name
        & netsh.exe wlan add profile filename="$f" user=all | Out-Null
        & netsh.exe wlan set profileparameter name="$ssid" connectionmode=auto | Out-Null
        $if = (Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.PhysicalMediaType -match '802.11|Native' } | Select-Object -First 1 -ExpandProperty Name)
        if (-not $if) { $if = 'Wi-Fi' }
        & netsh.exe wlan set profileorder name="$ssid" interface="$if" priority=1 | Out-Null
        Write-Log "Wi-Fi della scuola: profilo '$ssid' importato con priorita' massima"
        # i PC dei carrelli dimenticano tutte le altre reti; eccezioni: elenco in Mantieni-Wifi.txt (solo per PC in prova, es. a casa)
        $keep = @($ssid)
        if ($env:COMPUTERNAME -eq 'C2-02') { $keep += @(Get-PatternList (Join-Path $PSScriptRoot 'Mantieni-Wifi.txt')) }   # eccezione solo per il PC di prova a casa
        foreach ($l in (netsh wlan show profiles 2>$null)) {
            if ($l -match '(?i)profil' -and $l -match ':\s*(.+?)\s*$') {
                $n = $Matches[1]
                if ($keep -contains $n) { continue }
                & netsh.exe wlan delete profile name="$n" | Out-Null
                Write-Log "Wi-Fi: rete dimenticata: $n"
            }
        }
    } catch { Write-Log "Wi-Fi della scuola non impostato: $($_.Exception.Message)" 'AVVISO' }
}
function Remove-StoreApp([string]$name) {
    Get-AppxPackage -AllUsers -Name $name -ErrorAction SilentlyContinue | Remove-AppxPackage -AllUsers -ErrorAction SilentlyContinue
    Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -eq $name } |
        Remove-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Out-Null
}
# Edge: in Italia (Spazio economico europeo) si puo' disinstallare con il suo programma di installazione
function Remove-Edge {
    $root = Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application'
    $setup = Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^\d+\.' } |
             Sort-Object { [version]$_.Name } -Descending | ForEach-Object { Join-Path $_.FullName 'Installer\setup.exe' } | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (-not $setup) { Write-Log 'Edge non presente (o gia'' rimosso)'; return }
    if ($Simula) { Write-Log '[SIMULAZIONE] disinstallerei Microsoft Edge'; return }
    Get-Process -Name msedge -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    # senza questo valore il programma di Edge rifiuta di disinstallarsi (codice 532)
    New-Item -Path 'HKLM:\SOFTWARE\Microsoft\EdgeUpdateDev' -Force | Out-Null
    New-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\EdgeUpdateDev' -Name 'AllowUninstall' -PropertyType DWord -Value 1 -Force | Out-Null
    try {
        $p = Start-Process -FilePath $setup -ArgumentList '--uninstall --system-level --verbose-logging --force-uninstall' -PassThru -WindowStyle Hidden
        if (-not $p.WaitForExit(240000)) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue; Write-Log 'Disinstallazione di Edge troppo lunga, interrotta' 'AVVISO'; return }
        $left = Test-Path -LiteralPath (Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe')
        Write-Log ("Edge disinstallato (codice {0}){1}" -f $p.ExitCode, $(if ($left) { ': ma msedge.exe e'' ancora presente' } else { '' })) $(if ($left) { 'AVVISO' } else { 'INFO' })
    } catch { Write-Log "Edge non disinstallato: $($_.Exception.Message)" 'AVVISO' }
}
function Uninstall-Program([string]$pattern) {
    $keys = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    $found = @(Get-ItemProperty $keys -ErrorAction SilentlyContinue |
               Where-Object { $_.DisplayName -and $_.DisplayName -like $pattern })
    if ($found.Count -eq 0) { Write-Log "Programma non presente tra quelli di sistema: $pattern"; return }
    foreach ($p in $found) {
        $name = $p.DisplayName
        if ($Simula) { Write-Log "[SIMULAZIONE] disinstallerei: $name"; continue }
        $cmd = $null
        $us  = [string]$p.UninstallString
        if ($p.QuietUninstallString) { $cmd = [string]$p.QuietUninstallString }
        elseif ($us -match '(?i)msiexec') {
            $guid = [regex]::Match($us, '\{[0-9A-Fa-f-]+\}').Value
            if ($guid) { $cmd = "msiexec.exe /x $guid /qn /norestart" }
        }
        elseif ($us -match '(?i)(uninstall|helper)\.exe') { $cmd = $us + ' /S' }
        if (-not $cmd) { Write-Log "Da disinstallare a mano (nessuna procedura silenziosa): $name" 'AVVISO'; continue }
        try {
            $proc = Start-Process -FilePath 'cmd.exe' -ArgumentList ('/c "{0}"' -f $cmd) -PassThru -WindowStyle Hidden
            if (-not $proc.WaitForExit(180000)) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue; Write-Log "Disinstallazione troppo lunga, interrotta: $name" 'AVVISO' }
            else { Write-Log "Disinstallato (codice $($proc.ExitCode)): $name" }
        } catch { Write-Log "Disinstallazione non riuscita per $name : $($_.Exception.Message)" 'ERRORE' }
    }
}

# ======================================================== modalita' LOGON (lanciata dall'attivita')
if ($Logon) {
    $su = Get-LocalUser -Name $StudentName -ErrorAction SilentlyContinue
    if (-not $su) { exit 0 }
    $sid = $su.SID.Value
    Use-UserHive $sid { param($root) Set-UserConfig $root } | Out-Null
    if (Test-Path "Registry::HKEY_USERS\$sid") {
        $prof = (Get-CimInstance Win32_UserProfile -Filter "SID='$sid'" -ErrorAction SilentlyContinue).LocalPath
        if ($prof) {
            # tolgo le protezioni dell'accesso precedente per poter rifare i file
            & icacls.exe "$prof\Desktop" /remove:d $StudentName | Out-Null
            Get-ChildItem -LiteralPath "$prof\Desktop" -Force -ErrorAction SilentlyContinue | ForEach-Object { & icacls.exe $_.FullName /remove:d $StudentName | Out-Null }
            Move-ToBackup "$prof\Desktop" 'Desktop'
            Move-ToBackup "$prof\Downloads" 'Download'
            try {
                $ws  = New-Object -ComObject WScript.Shell
                $lnk = $ws.CreateShortcut("$prof\Desktop\Lavori.lnk")
                $lnk.TargetPath = $LavoriDir
                $lnk.Save()
            } catch { }
            # collegamento "Cambia classe" (avvia l'attivita' a richiesta: da qui PowerShell non si puo' lanciare)
            try {
                $lc = $ws.CreateShortcut("$prof\Desktop\Cambia classe.lnk")
                $lc.TargetPath = "$env:WINDIR\System32\schtasks.exe"
                $lc.Arguments = "/run /tn $ClassTaskName"
                $lc.IconLocation = "$env:WINDIR\System32\shell32.dll,43"
                $lc.WindowStyle = 7
                $lc.Save()
            } catch { }
            # istruzioni per gli alunni sul desktop (si rifanno a ogni accesso)
            $istr = Join-Path $Base 'Istruzioni-Studenti.txt'
            if (Test-Path -LiteralPath $istr) { try { Copy-Item -LiteralPath $istr -Destination "$prof\Desktop\COME USARE IL PC.txt" -Force } catch { } }
            # programmi installati dall'alunno nella propria cartella (es. Opera GX): rimossi, tranne i consentiti
            $allowFile = Join-Path $Base 'AppConsentite-Programmi.txt'
            if (Test-Path -LiteralPath $allowFile) {
                $allowP = @(Get-PatternList $allowFile)
                $pf = Join-Path $prof 'AppData\Local\Programs'
                if (Test-Path -LiteralPath $pf) {
                    foreach ($f in (Get-ChildItem -LiteralPath $pf -Directory -Force -ErrorAction SilentlyContinue)) {
                        if ($f.Name -eq 'Common' -or $f.Name -like 'Microsoft*') { continue }
                        if (Test-MatchAny $f.Name $allowP) { continue }
                        Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Path -and $_.Path -like "$($f.FullName)\*" } | Stop-Process -Force -ErrorAction SilentlyContinue
                        Remove-Item -LiteralPath $f.FullName -Recurse -Force -ErrorAction SilentlyContinue
                        Write-Log "Programma installato dall'utente rimosso: $($f.Name)"
                    }
                }
            }
        }
    }
    # app di Microsoft Store installate dall'alunno (es. WhatsApp): rimosse, tranne quelle consentite
    $allowS = @(Get-PatternList (Join-Path $Base 'AppConsentite-Store.txt'))
    if ($allowS.Count -gt 0) {
        foreach ($pk in @(Get-AppxPackage -User $sid -ErrorAction SilentlyContinue |
                 Where-Object { -not $_.IsFramework -and -not $_.NonRemovable -and -not $_.IsResourcePackage -and $_.SignatureKind -eq 'Store' })) {
            if (Test-MatchAny $pk.Name ($StoreProtected + $allowS)) { continue }
            Remove-AppxPackage -Package $pk.PackageFullName -User $sid -ErrorAction SilentlyContinue
            Write-Log "App di Store dell'utente rimossa: $($pk.Name)"
        }
    }
    Write-Log 'Accesso di Studente: blocchi riapplicati, desktop e download puliti'
    # a ogni accensione la classe va scelta di nuovo
    Remove-ItemProperty -Path "Registry::HKEY_USERS\$sid\Software\Carrello" -Name 'Classe', 'ClasseOra' -ErrorAction SilentlyContinue
    # copia giornaliera di Lavori e registro delle modifiche, poi la scelta della classe
    $lv = Join-Path $Base 'Lavori.ps1'
    if (Test-Path -LiteralPath $lv) {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $lv -Snapshot
        Start-ScheduledTask -TaskName $ClassTaskName -ErrorAction SilentlyContinue
    }
    Set-ChromeShortcutArgs
    # Edge e Chrome ricreano il collegamento sul desktop al primo avvio: seconda pulizia dopo un minuto
    Get-ChildItem 'C:\Users\Public\Desktop' -Filter '*.lnk' -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'Microsoft Edge*' } | Remove-Item -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 60
    $prof2 = (Get-CimInstance Win32_UserProfile -Filter "SID='$sid'" -ErrorAction SilentlyContinue).LocalPath
    if ($prof2) { Move-ToBackup "$prof2\Desktop" 'Desktop' }
    Get-ChildItem 'C:\Users\Public\Desktop' -Filter '*.lnk' -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'Microsoft Edge*' } | Remove-Item -Force -ErrorAction SilentlyContinue
    exit 0
}

# ======================================================== controlli iniziali
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
           ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host 'Serve eseguire lo script come amministratore (usa il file INSTALLA.bat).' -ForegroundColor Red
    exit 1
}
if ($env:USERNAME -eq $StudentName) {
    Write-Host 'Non eseguire questo script dall''account Studente.' -ForegroundColor Red
    exit 1
}

$grpAdmin = (Get-LocalGroup -SID 'S-1-5-32-544').Name
$grpUsers = (Get-LocalGroup -SID 'S-1-5-32-545').Name

if (-not $Logon -and -not $Aggiorna) { Show-Banner }
if ($Simula) { Write-Host 'MODALITA SIMULAZIONE: non viene modificato nulla.' -ForegroundColor Yellow }

# ======================================================== ANNULLA
if ($Annulla) {
    Write-Log 'ANNULLA: inizio'
    Remove-LogonTask
    Remove-UpdateTask
    if (-not $Simula) { Unregister-ScheduledTask -TaskName $ClassTaskName -Confirm:$false -ErrorAction SilentlyContinue; Unregister-ScheduledTask -TaskName $NetTaskName -Confirm:$false -ErrorAction SilentlyContinue }
    Remove-Autologon
    Remove-Srp
    Remove-MachineConfig
    $su = Get-LocalUser -Name $StudentName -ErrorAction SilentlyContinue
    if ($su) {
        $done = Use-UserHive $su.SID.Value { param($root) Remove-UserConfig $root }
        if (-not $done) { Write-Log 'Profilo di Studente non trovato: nessun blocco utente da togliere' }
    }
    $state = Get-State
    foreach ($n in @($state.Demoted)) {
        if (-not $n) { continue }
        if (-not $Simula) {
            Enable-LocalUser -Name $n -ErrorAction SilentlyContinue
            Add-LocalGroupMember -Group $grpAdmin -Member $n -ErrorAction SilentlyContinue
        }
        Write-Log "Account '$n' ripristinato (amministratore, attivo)"
    }
    if (-not $Simula) { Save-State ([pscustomobject]@{ Demoted = @() }) }
    Write-Log 'ANNULLA: completato. Riavviare il PC. (La gestione remota SSH resta attiva.)'
    exit 0
}

# ======================================================== CONFIGURAZIONE
if ($Aggiorna) {
    if ($env:COMPUTERNAME -notmatch '^C(\d)-(\d{2})$') { Write-Log "Aggiornamento: nome PC '$($env:COMPUTERNAME)' non valido" 'ERRORE'; exit 1 }
    $Carrello = [int]$Matches[1]; $NumeroPC = [int]$Matches[2]
    $SenzaBackup = $true; $NoRiavvio = $true
}
function Read-Numero([string]$domanda, [int]$min, [int]$max) {
    while ($true) {
        $t = Read-Host $domanda
        $n = 0
        if ([int]::TryParse($t.Trim(), [ref]$n) -and $n -ge $min -and $n -le $max) { return $n }
        Write-Host "Scrivi un numero da $min a $max e premi Invio." -ForegroundColor Yellow
    }
}
if (-not $Carrello) { $Carrello = Read-Numero 'Numero del carrello (1 o 2)' 1 9 }
if (-not $NumeroPC) { $NumeroPC = Read-Numero "Numero del PC (numero d'appello)" 1 99 }
$newName = 'C{0}-{1:00}' -f $Carrello, $NumeroPC

Write-Host ''
Write-Host "Questo PC diventa: $newName" -ForegroundColor Green
if (-not $Aggiorna -and -not $Simula) {
    Write-Host 'Se il nome NON e'' giusto premi CTRL+C adesso. Si parte tra 10 secondi...' -ForegroundColor Yellow
    for ($i = 10; $i -gt 0; $i--) { Write-Host -NoNewline ("{0} " -f $i); Start-Sleep -Seconds 1 }
    Write-Host ''
}
Write-Log "INSTALLA v${Versione} - inizio (nome previsto $newName)"

if (-not $Aggiorna) {
    $settings  = Get-Settings
    $adminPw   = $settings['AdminPassword']
    $studentPw = $settings['StudentPassword']
}

# --- cartella di servizio
if (-not $Simula) {
    if (-not (Test-Path $Base)) { New-Item -ItemType Directory -Path $Base -Force | Out-Null }
    Copy-Item -LiteralPath $PSCommandPath -Destination $ScriptCopy -Force
    $al = Join-Path $PSScriptRoot 'AppConsentite-Programmi.txt'
    if (Test-Path -LiteralPath $al) { Copy-Item -LiteralPath $al -Destination $Base -Force }
    $als = Join-Path $PSScriptRoot 'AppConsentite-Store.txt'
    if (Test-Path -LiteralPath $als) { Copy-Item -LiteralPath $als -Destination $Base -Force }
    Remove-Item -LiteralPath (Join-Path $Base 'Configura-PC-Carrello.ps1') -Force -ErrorAction SilentlyContinue
    # aggiornamento automatico: script, sfondi e numero di versione
    foreach ($f in 'Aggiorna-PC.ps1', 'Lavori.ps1', 'Classi.txt', 'Istruzioni-Studenti.txt', 'ElencoApp-da-rimuovere.txt', 'ElencoProgrammi-da-rimuovere.txt') {
        $src = Join-Path $PSScriptRoot $f
        if (Test-Path -LiteralPath $src) { try { Copy-Item -LiteralPath $src -Destination $Base -Force } catch { Write-Log "Copia di $f non riuscita: $($_.Exception.Message)" 'AVVISO' } }
    }
    $sfSrc = Join-Path $PSScriptRoot 'Sfondi'
    if ((Test-Path -LiteralPath $sfSrc) -and ($PSScriptRoot -ne $Base)) {
        try { Copy-Item -LiteralPath $sfSrc -Destination $Base -Recurse -Force } catch { }
    }
    if (-not $Aggiorna) {
        $vf = Join-Path $PSScriptRoot 'VERSIONE.txt'
        $b0 = if (Test-Path -LiteralPath $vf) { (Get-Content -LiteralPath $vf -Raw).Trim() } else { '0' }
        Set-Content -Path $BuildFile -Value $b0 -Encoding ascii
    }
    Protect-BaseFolder
}

# --- punto di ripristino
if (-not $Simula -and -not $Aggiorna) {
    # il punto di ripristino puo' restare appeso se Windows sta installando aggiornamenti: massimo 3 minuti
    try {
        Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction Stop
        $job = Start-Job { Checkpoint-Computer -Description 'Prima di Installa-PC' -RestorePointType MODIFY_SETTINGS -ErrorAction Stop }
        if (Wait-Job $job -Timeout 180) { Receive-Job $job -ErrorAction Stop | Out-Null; Write-Log 'Punto di ripristino creato' }
        else { Stop-Job $job; Write-Log 'Punto di ripristino non creato: Windows e'' occupato (tempo scaduto), proseguo' 'AVVISO' }
        Remove-Job $job -Force -ErrorAction SilentlyContinue
    } catch { Write-Log "Punto di ripristino non creato: $($_.Exception.Message)" 'AVVISO' }
}

# --- backup dei file degli utenti: PRIMA di qualsiasi modifica
if (-not $SenzaBackup -and -not $Aggiorna) {
    $stampB = Get-Date -Format 'yyyyMMdd-HHmm'
    $sources = New-Object System.Collections.Generic.List[object]
    foreach ($d in (Get-ChildItem 'C:\Users' -Directory -Force -ErrorAction SilentlyContinue)) {
        if ($d.Name -in 'Public', 'Default', 'Default User', 'All Users') { continue }
        if (-not (Test-Path -LiteralPath (Join-Path $d.FullName 'NTUSER.DAT'))) { continue }
        $bases = @($d.FullName) + @(Get-ChildItem $d.FullName -Directory -Force -Filter 'OneDrive*' -ErrorAction SilentlyContinue | ForEach-Object FullName)
        foreach ($b in $bases) {
            foreach ($f in 'Desktop', 'Documents', 'Downloads', 'Pictures', 'Videos', 'Music') {
                $p = Join-Path $b $f
                if (Test-Path -LiteralPath $p) { $sources.Add(@{ Src = $p; Rel = $p.Substring('C:\Users\'.Length); Bytes = [int64]0 }) }
            }
        }
    }
    if (Test-Path -LiteralPath $LavoriDir) { $sources.Add(@{ Src = $LavoriDir; Rel = '_Lavori'; Bytes = [int64]0 }) }

    $total = [int64]0
    foreach ($s in $sources) {
        $s.Bytes = Get-FolderBytes $s.Src
        $total += $s.Bytes
        if ($s.Bytes -gt 0) { Write-Log ("Backup - da copiare: {0}  ({1} MB)" -f $s.Rel, [math]::Round($s.Bytes / 1MB, 1)) }
    }
    Write-Log ("Backup - totale: {0} MB in {1}" -f [math]::Round($total / 1MB, 0), $BackupDir)

    $okBackup = $true
    if ($Simula) {
        Write-Log '[SIMULAZIONE] eseguirei il backup qui sopra prima di qualsiasi modifica'
    } elseif ($total -eq 0) {
        Write-Log 'Backup: nessun file da salvare'
    } else {
        $free = (Get-PSDrive -Name C).Free
        if ($free -lt ($total * 1.1 + 2GB)) {
            Write-Log ("Spazio libero insufficiente per il backup ({0} MB liberi)" -f [math]::Round($free / 1MB, 0)) 'ERRORE'
            $okBackup = $false
        } else {
            Initialize-BackupDir
            $dstRoot = Join-Path $BackupDir "Iniziale-$stampB"
            foreach ($s in $sources) {
                if ($s.Bytes -eq 0) { continue }
                $dst = Join-Path $dstRoot $s.Rel
                & robocopy.exe $s.Src $dst /E /COPY:DAT /DCOPY:DAT /R:1 /W:1 /XJ /XA:O /MAX:2147483648 /NFL /NDL /NP /NJH /NJS | Out-Null
                if ($LASTEXITCODE -ge 8) { $okBackup = $false; Write-Log "Backup con errori: $($s.Src) (codice $LASTEXITCODE)" 'ERRORE' }
            }
            $copied = Get-FolderBytes $dstRoot
            Write-Log ("Backup copiato in {0}: {1} MB" -f $dstRoot, [math]::Round($copied / 1MB, 0))
            if ($okBackup) {
                try {
                    $letter = (Split-Path -Path $PSScriptRoot -Qualifier).TrimEnd(':')
                    $disk = Get-Partition -DriveLetter $letter -ErrorAction Stop | Get-Disk -ErrorAction Stop
                    if ($disk.BusType -eq 'USB') {
                        if ((Get-PSDrive -Name $letter).Free -gt ($copied + 500MB)) {
                            $usbDst = Join-Path $PSScriptRoot ('Backup-PC\{0}\Iniziale-{1}' -f $env:COMPUTERNAME, $stampB)
                            & robocopy.exe $dstRoot $usbDst /E /COPY:DAT /DCOPY:DAT /R:1 /W:1 /NFL /NDL /NP /NJH /NJS | Out-Null
                            if ($LASTEXITCODE -ge 8) { Write-Log "Copia sulla chiavetta con errori (codice $LASTEXITCODE)" 'AVVISO' }
                            else { Write-Log "Backup copiato anche sulla chiavetta: $usbDst" }
                        } else { Write-Log 'Chiavetta troppo piena: copia sulla chiavetta saltata' 'AVVISO' }
                    }
                } catch { Write-Log "Copia sulla chiavetta non eseguita: $($_.Exception.Message)" 'AVVISO' }
            }
        }
        if (-not $okBackup) {
            Write-Host 'Il backup NON e'' riuscito: mi fermo per sicurezza. Libera spazio e rilancia (oppure usa -SenzaBackup).' -ForegroundColor Red
            exit 1
        }
    }
} elseif (-not $Aggiorna) { Write-Log 'Backup saltato (-SenzaBackup)' 'AVVISO' }

# --- pulizia iniziale, account: solo nell'installazione (non negli aggiornamenti automatici)
if ($Aggiorna) { $stu = Get-LocalUser -Name $StudentName -ErrorAction SilentlyContinue }
if (-not $Aggiorna) {

$tempDirs = @("$env:WINDIR\Temp") +
            @(Get-ChildItem 'C:\Users' -Directory -Force -ErrorAction SilentlyContinue |
              ForEach-Object { Join-Path $_.FullName 'AppData\Local\Temp' })
$limit = (Get-Date).AddDays(-3)
$freed = 0
foreach ($t in $tempDirs) {
    if (-not (Test-Path -LiteralPath $t)) { continue }
    if ($Simula) { Write-Log "[SIMULAZIONE] pulirei $t"; continue }
    $old = @(Get-ChildItem -LiteralPath $t -Recurse -Force -File -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -lt $limit })
    $freed += ($old | Measure-Object -Property Length -Sum).Sum
    $old | Remove-Item -Force -ErrorAction SilentlyContinue
}
if ($Simula) {
    Write-Log '[SIMULAZIONE] svuoterei il cestino ed eseguirei il TRIM su C:'
} else {
    Write-Log ("Pulizia iniziale: liberati circa {0} MB di file temporanei" -f [math]::Round($freed / 1MB, 0))
    Clear-RecycleBin -Force -ErrorAction SilentlyContinue
    Clear-DnsClientCache -ErrorAction SilentlyContinue
    try { Optimize-Volume -DriveLetter C -ReTrim -ErrorAction Stop } catch { }
}

# --- account amministratore
$adm = Get-LocalUser -Name $AdminName -ErrorAction SilentlyContinue
if (-not $adm) {
    if ($Simula) {
        Write-Log "[SIMULAZIONE] creerei l'account $AdminName (amministratore)"
    } else {
        try {
            New-LocalUser -Name $AdminName -Password (ConvertTo-SecureString $adminPw -AsPlainText -Force) -FullName 'Amministratore docente' -Description 'Gestione del carrello' -PasswordNeverExpires -AccountNeverExpires -ErrorAction Stop | Out-Null
            Add-LocalGroupMember -Group $grpAdmin -Member $AdminName -ErrorAction Stop
            Write-Log "Account $AdminName creato"
        } catch { Write-Log "ERRORE: account $AdminName non creato: $($_.Exception.Message)" 'ERRORE' }
    }
} else {
    if (-not $Simula) {
        Enable-LocalUser -Name $AdminName -ErrorAction SilentlyContinue
        Add-LocalGroupMember -Group $grpAdmin -Member $AdminName -ErrorAction SilentlyContinue
        # la password dell'amministratore e' sempre quella del file Impostazioni-scuola.txt (uguale su tutti i PC)
        try { Set-LocalUser -Name $AdminName -Password (ConvertTo-SecureString $adminPw -AsPlainText -Force) -ErrorAction Stop; Write-Log "Account $AdminName gia' presente: password allineata al file delle impostazioni" }
        catch { Write-Log "Password di $AdminName non aggiornata: $($_.Exception.Message)" 'AVVISO' }
    } else { Write-Log "[SIMULAZIONE] allineerei la password di $AdminName al file delle impostazioni" }
}
if (-not $Simula) {
    $a = Get-LocalUser -Name $AdminName -ErrorAction SilentlyContinue
    $inAdmins = Get-LocalGroupMember -Group $grpAdmin -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "*\$AdminName" }
    if (-not $a -or -not $a.Enabled -or -not $inAdmins) {
        Write-Host "L'account $AdminName non e' pronto: mi fermo per sicurezza." -ForegroundColor Red
        exit 1
    }
}

# --- account studente
$stu = Get-LocalUser -Name $StudentName -ErrorAction SilentlyContinue
if ($Simula) {
    Write-Log "[SIMULAZIONE] creerei/aggiornerei l'account $StudentName (password dal file delle impostazioni)"
} else {
    $secS = ConvertTo-SecureString $studentPw -AsPlainText -Force
    if (-not $stu) {
        try {
            New-LocalUser -Name $StudentName -Password $secS -FullName 'Studente' -Description 'Account condiviso per gli alunni' -PasswordNeverExpires -UserMayNotChangePassword -ErrorAction Stop | Out-Null
            Write-Log "Account $StudentName creato"
        } catch { Write-Log "ERRORE: account $StudentName non creato: $($_.Exception.Message)" 'ERRORE' }
    } else {
        Set-LocalUser -Name $StudentName -Password $secS -ErrorAction SilentlyContinue
        Enable-LocalUser -Name $StudentName -ErrorAction SilentlyContinue
    }
    $stu = Get-LocalUser -Name $StudentName -ErrorAction SilentlyContinue
    if (-not $stu) {
        Write-Host "L'account $StudentName non e' stato creato: mi fermo per sicurezza." -ForegroundColor Red
        exit 1
    }
    Add-LocalGroupMember -Group $grpUsers -Member $StudentName -ErrorAction SilentlyContinue
    if (Get-LocalGroupMember -Group $grpAdmin -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "*\$StudentName" }) {
        Remove-LocalGroupMember -Group $grpAdmin -Member $StudentName -ErrorAction SilentlyContinue
        Write-Log "$StudentName tolto dagli amministratori"
    }
}

# --- altri amministratori (es. "Utente"): declassati e disattivati, mai cancellati
$state = Get-State
$demoted = @($state.Demoted | Where-Object { $_ })
$others = @(Get-LocalGroupMember -Group $grpAdmin -ErrorAction SilentlyContinue | Where-Object { $_.Name.Split('\')[-1] -notin @($AdminName, 'Administrator') })
foreach ($m in $others) {
    $n = $m.Name.Split('\')[-1]
    if ($m.PrincipalSource -ne 'Local') {
        Write-Log "Attenzione: '$($m.Name)' e' un account non locale con privilegi di amministratore: lo lascio com'e'." 'AVVISO'
        continue
    }
    $lu = Get-LocalUser -Name $n -ErrorAction SilentlyContinue
    if (-not $lu -or -not $lu.Enabled) { continue }
    if ($Simula) { Write-Log "[SIMULAZIONE] toglierei '$n' dagli amministratori e lo disattiverei" }
    else {
        Remove-LocalGroupMember -Group $grpAdmin -Member $n -ErrorAction SilentlyContinue
        Disable-LocalUser -Name $n -ErrorAction SilentlyContinue
        $demoted += $n
        Write-Log "Account '$n': privilegi tolti e account disattivato (i suoi file sono nel backup)"
    }
}
$state.Demoted = $demoted
Save-State $state

}   # fine installazione-only

# --- cartella Lavori
if ($Simula) { Write-Log "[SIMULAZIONE] creerei $LavoriDir" }
else {
    if (-not (Test-Path $LavoriDir)) { New-Item -ItemType Directory -Path $LavoriDir -Force | Out-Null }
    & icacls.exe $LavoriDir /grant '*S-1-5-32-545:(OI)(CI)M' | Out-Null
    Write-Log "Cartella $LavoriDir pronta"
    $lv = Join-Path $PSScriptRoot 'Lavori.ps1'
    if (Test-Path -LiteralPath $lv) { & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $lv -Imposta }
}

# --- sfondo con il numero del PC
New-WallpaperImage $WallFile $newName $Carrello
Install-GeoGebra
# --- barra e Start dell'amministratore (il layout vale solo al primo accesso: si crea il profilo ora se manca)
$admSid = (Get-LocalUser -Name $AdminName -ErrorAction SilentlyContinue).SID.Value
if (-not $Aggiorna) {
    New-TaskbarLayout 'Admin'
    $script:AdminPinsJson = $script:StartPinsJson
    Set-DefaultLayout $TaskbarXmlAdmin
    if ($admSid -and -not $Simula -and -not (Get-CimInstance Win32_UserProfile -ErrorAction SilentlyContinue | Where-Object { $_.SID -eq $admSid -and $_.LocalPath })) {
        New-StudentProfile $admSid $AdminName
    }
}
New-TaskbarLayout 'Studente'
Set-DefaultLayout $TaskbarXml $true

# --- impostazioni di sistema
Set-MachineConfig
Set-PowerConfig
Set-Autologon
if ($ConBloccoProgrammi) { Set-Srp } else { Remove-Srp }

# --- impostazioni dell'amministratore (se il profilo esiste)
if ($admSid) {
    [void](Use-UserHive $admSid { param($root) Set-AdminConfig $root })
    if (-not $Aggiorna) { Reset-AdminShell $admSid }
}

# --- impostazioni di Studente
$sid = if ($stu) { $stu.SID.Value } else { 'S-1-5-21-SIMULATO' }
$done = Use-UserHive $sid { param($root) Set-UserConfig $root }
# il profilo di Studente NON si crea da script: nasce al primo accesso (accesso automatico) e prende barra e Start dal profilo Default
if (-not $done) { Write-Log 'Profilo di Studente non ancora presente: nasce al primo accesso con barra e Start della scuola; i blocchi li scrive l''attivita'' di accesso' }
Set-LogonTask
Set-ClassTask
Set-NetTask
if (-not $Aggiorna) { Set-UpdateTask }

# --- gestione remota e Wi-Fi
Enable-RemoteAccess
Set-WifiAuto
Set-SchoolWifi

# --- Veyon Service (i docenti vedono/bloccano gli schermi, aprono siti, inviano file): installato CHIUSO;
#     si apre da solo con -Aggiorna quando nel pacchetto arriva veyon-docenti-pubblica.key (vedi Docenti/PIANO_DOCENTI.md)
$vd = $PSScriptRoot
if (-not (Test-Path -LiteralPath (Join-Path $vd 'Veyon-Comune.ps1'))) { $vd = Join-Path $PSScriptRoot 'Docenti' }
if (Test-Path -LiteralPath (Join-Path $vd 'Veyon-Carrello.ps1')) {
    try {
        $vArgs = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -Dir "{1}"' -f (Join-Path $vd 'Veyon-Carrello.ps1'), $vd
        if ($Simula) { $vArgs += ' -Simula' }
        $vp = Start-Process -FilePath 'powershell.exe' -ArgumentList $vArgs -Wait -PassThru -WindowStyle Hidden
        Write-Log ("Veyon Service: codice di uscita {0} (dettagli nelle righe VEYON del registro)" -f $vp.ExitCode) $(if ($vp.ExitCode -eq 0) { 'INFO' } else { 'AVVISO' })
    } catch { Write-Log "Veyon non configurato: $($_.Exception.Message)" 'AVVISO' }
} else { Write-Log 'Veyon: script non trovati (cartella Docenti): saltato' 'AVVISO' }

# --- rimozione app e programmi
$apps = @(Get-PatternList (Join-Path $PSScriptRoot 'ElencoApp-da-rimuovere.txt'))
foreach ($a in $apps) {
    if ($Simula) {
        $pres = @(Get-AppxPackage -AllUsers -Name $a -ErrorAction SilentlyContinue).Count
        Write-Log ("[SIMULAZIONE] app {0}: {1}" -f $a, $(if ($pres) { 'presente, verra'' rimossa' } else { 'non presente' }))
        continue
    }
    Remove-StoreApp $a
    Write-Log "App rimossa (se presente): $a"
}
$progs = @(Get-PatternList (Join-Path $PSScriptRoot 'ElencoProgrammi-da-rimuovere.txt'))
if (-not $Simula -and $progs.Count -gt 0) {
    Get-Process -Name 'firefox', 'opera', 'browser_assistant', 'WinRAR' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
}
foreach ($pg in $progs) { Uninstall-Program $pg }
# Edge: la disinstallazione e' rifiutata da Windows (codice 532): resta installato ma bloccato per Studente e senza icone
#Remove-Edge

# modalita' "solo app consentite": rimuove tutto cio' che non e' in elenco
$allowStore = @(Get-PatternList (Join-Path $PSScriptRoot 'AppConsentite-Store.txt'))
$allowProg  = @(Get-PatternList (Join-Path $PSScriptRoot 'AppConsentite-Programmi.txt'))
if (-not $NoSoloConsentite -and ($allowStore.Count -gt 0 -or $allowProg.Count -gt 0)) {
    Write-Log "Modalita 'solo app consentite': analisi di cio' che e' installato"
    $candStore = @(); $keptStore = @(); $candProg = @(); $keptProg = @(); $candFolders = @()
    if ($allowStore.Count -gt 0) {
        $storeNames = @(Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue |
            Where-Object { -not $_.IsFramework -and -not $_.NonRemovable -and -not $_.IsResourcePackage -and $_.SignatureKind -eq 'Store' } |
            Select-Object -ExpandProperty Name -Unique)
        foreach ($n in $storeNames) {
            if (Test-MatchAny $n ($StoreProtected + $allowStore)) { $keptStore += $n } else { $candStore += $n }
        }
    }
    if ($allowProg.Count -gt 0) {
        $progKeys = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
        $progAll = @(Get-ItemProperty $progKeys -ErrorAction SilentlyContinue | Where-Object {
            $_.DisplayName -and -not $_.SystemComponent -and -not $_.ParentKeyName -and
            ($_.ReleaseType -notin 'Update', 'Hotfix', 'Security Update', 'Update Rollup', 'Service Pack') -and
            ($_.UninstallString -or $_.QuietUninstallString) } | Sort-Object DisplayName -Unique)
        foreach ($p in $progAll) {
            $protected = (Test-MatchAny $p.DisplayName ($ProgProtectedName + $allowProg)) -or (Test-MatchAny ([string]$p.Publisher) $ProgProtectedPublisher)
            if ($protected) { $keptProg += $p } else { $candProg += $p }
        }
        foreach ($d in (Get-ChildItem 'C:\Users' -Directory -Force -ErrorAction SilentlyContinue)) {
            $pf = Join-Path $d.FullName 'AppData\Local\Programs'
            if (-not (Test-Path -LiteralPath $pf)) { continue }
            foreach ($f in (Get-ChildItem -LiteralPath $pf -Directory -Force -ErrorAction SilentlyContinue)) {
                if ($f.Name -eq 'Common' -or $f.Name -like 'Microsoft*') { continue }
                if (-not (Test-MatchAny $f.Name $allowProg)) { $candFolders += $f.FullName }
            }
        }
    }
    Write-Log ("SOLO CONSENTITE - TENUTE: {0} app di Store, {1} programmi" -f $keptStore.Count, $keptProg.Count)
    Write-Log ("SOLO CONSENTITE - DA RIMUOVERE: {0} app di Store, {1} programmi, {2} cartelle di programmi utente" -f $candStore.Count, $candProg.Count, $candFolders.Count)
    foreach ($n in $candStore)   { Write-Log "  DA RIMUOVERE (Store): $n" }
    foreach ($p in $candProg)    { Write-Log "  DA RIMUOVERE (programma): $($p.DisplayName)  [$($p.Publisher)]" }
    foreach ($f in $candFolders) { Write-Log "  DA RIMUOVERE (cartella utente): $f" }
    if ($Simula) {
        Write-Log '[SIMULAZIONE] nessuna rimozione effettuata'
    } elseif ($candStore.Count -gt 70 -or $candProg.Count -gt 30 -or $candFolders.Count -gt 30) {
        Write-Log 'Troppi elementi da rimuovere: controlla AppConsentite-*.txt. Rimozione saltata per sicurezza.' 'AVVISO'
    } else {
        foreach ($n in $candStore) { Remove-StoreApp $n; Write-Log "App di Store rimossa: $n" }
        foreach ($p in $candProg)  { Uninstall-Program ([WildcardPattern]::Escape($p.DisplayName)) }
        foreach ($f in $candFolders) {
            Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Path -and $_.Path -like "$f\*" } | Stop-Process -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $f -Recurse -Force -ErrorAction SilentlyContinue
            Write-Log "Cartella rimossa: $f"
        }
    }
}

# --- nome del PC
if ($env:COMPUTERNAME -ne $newName) {
    if ($Simula) { Write-Log "[SIMULAZIONE] rinominerei il PC in $newName" }
    else { try { Rename-Computer -NewName $newName -Force -ErrorAction Stop; Write-Log "PC rinominato in $newName (effettivo al riavvio)" } catch { Write-Log "Rinomina non riuscita: $($_.Exception.Message)" 'ERRORE' } }
}

# ======================================================== verifica finale
function Show-Verifica {
    $risultati = New-Object System.Collections.Generic.List[object]
    function Add-Check([string]$nome, [scriptblock]$test) {
        $ok = $false
        try { $ok = [bool](& $test) } catch { $ok = $false }
        $risultati.Add([pscustomobject]@{ Nome = $nome; Ok = $ok })
    }
    $sm = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs'
    $hasLnk = { param($n) [bool](Get-ChildItem -LiteralPath $sm -Recurse -Filter $n -ErrorAction SilentlyContinue | Select-Object -First 1) }
    Add-Check "Nome del PC: $newName (attivo dopo il riavvio)" { (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName').ComputerName -eq $newName }
    Add-Check 'Account amministratore AdminDocente' { (Get-LocalUser $AdminName).Enabled -and (Get-LocalGroupMember -Group $grpAdmin | Where-Object { $_.Name -like "*\$AdminName" }) }
    Add-Check 'Account Studente con accesso automatico' { (Get-LocalUser $StudentName).Enabled -and (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon').AutoAdminLogon -eq '1' }
    Add-Check 'Rete Wi-Fi della scuola (Scuola-Laboratorio)' { (netsh wlan show profiles) -match 'Scuola-Laboratorio' }
    Add-Check 'Gestione remota (SSH) attiva' { (Get-Service sshd).Status -eq 'Running' }
    Add-Check 'Chrome installato' { Test-Path "$env:ProgramFiles\Google\Chrome\Application\chrome.exe" }
    foreach ($a in 'Word', 'Excel', 'PowerPoint') { $nn = "$a.lnk"; $blk = { & $hasLnk $nn }.GetNewClosure(); Add-Check "$a installato" $blk }
    Add-Check 'GeoGebra installato' { & $hasLnk 'GeoGebra*.lnk' }
    Add-Check 'Scratch installato' { & $hasLnk 'Scratch*.lnk' }
    Add-Check 'Chrome in modalita'' ospite con Google' { (Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Google\Chrome').BrowserGuestModeEnforced -eq 1 }
    Add-Check 'Aggiornamento automatico dello script (attivita)' { Get-ScheduledTask -TaskName $UpdTaskName }
    Add-Check 'Attivita di accesso, scelta classe e scambio classi' { (Get-ScheduledTask -TaskName $TaskName) -and (Get-ScheduledTask -TaskName $ClassTaskName) -and (Get-ScheduledTask -TaskName $NetTaskName) }
    Add-Check 'Windows Update automatico' { (Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU').NoAutoUpdate -eq 0 }
    Add-Check 'Veyon (servizio installato, chiuso)' { Get-Service -Name VeyonService }
    Add-Check 'Cartella Lavori e sfondo con il numero' { (Test-Path $LavoriDir) -and (Test-Path $WallFile) }
    Add-Check 'App non volute rimosse (Solitario, Xbox, Teams, Copilot)' { -not (Get-AppxPackage -AllUsers | Where-Object { $_.Name -match 'Solitaire|GamingApp|XboxGamingOverlay|MSTeams|MicrosoftTeams|Copilot' }) }
    Write-Host ''
    Write-Host '--- CONTROLLO FINALE ---' -ForegroundColor Cyan
    $righe = @()
    foreach ($r in $risultati) {
        if ($r.Ok) { Write-Host ('  [ OK ]     ' + $r.Nome) -ForegroundColor Green; $righe += ('OK      ' + $r.Nome) }
        else { Write-Host ('  [ ERRORE ] ' + $r.Nome) -ForegroundColor Red; $righe += ('ERRORE  ' + $r.Nome) }
    }
    $err = @($risultati | Where-Object { -not $_.Ok }).Count
    Write-Host ''
    if ($err -eq 0) { Write-Host 'TUTTO A POSTO.' -ForegroundColor Green } else { Write-Host ("ATTENZIONE: {0} controlli non riusciti. Scrivi il nome del PC e la riga rossa a Paride." -f $err) -ForegroundColor Red }
    $testo = @("Installazione $newName - $(Get-Date -Format 'yyyy-MM-dd HH:mm')", "$($Firma[0]) (v$Versione) - $($Firma[1])", '') + $righe
    try { Set-Content -LiteralPath (Join-Path $Base 'verifica.txt') -Value $testo -Encoding UTF8 } catch { }
    try {
        # sulla penna la cartella Report sta accanto a INSTALLA.bat (lo script e' in NON-TOCCARE)
        $rep = if ((Split-Path $PSScriptRoot -Leaf) -eq 'NON-TOCCARE') { Join-Path (Split-Path $PSScriptRoot -Parent) 'Report' } else { Join-Path $PSScriptRoot 'Report' }
        New-Item -ItemType Directory -Path $rep -Force -ErrorAction Stop | Out-Null
        Set-Content -LiteralPath (Join-Path $rep ("Verifica_{0}.txt" -f $newName)) -Value $testo -Encoding UTF8
    } catch { }
    Set-Content -LiteralPath (Join-Path $Base 'Installato-da.txt') -Value @("$($Firma[0]) (v$Versione)", $Firma[1], "PC: $newName", "Data: $(Get-Date -Format 'yyyy-MM-dd HH:mm')") -Encoding UTF8
}

# ======================================================== riepilogo
if ($Aggiorna) { Write-Log "Aggiornamento di configurazione applicato (script v$Versione)"; exit 0 }
Write-Host ''
if ($Simula) {
    Write-Host "SIMULAZIONE FINITA. Risultato nel file: $SimLog" -ForegroundColor Green
    exit 0
}
Show-Verifica
Write-Host ''
Write-Host '=== FATTO ===' -ForegroundColor Green
Show-Banner
Write-Host "Nome PC         : $newName (dopo il riavvio)"
Write-Host "Amministratore  : $AdminName   (password nel file Impostazioni-scuola.txt)"
Write-Host "Alunni          : $StudentName  (accesso automatico)"
Write-Host "Cartella lavori : $LavoriDir"
Write-Host "Backup file     : $BackupDir"
Write-Host "Log             : $LogFile"
if ($NoRiavvio) {
    Write-Host 'Riavvio non eseguito (-NoRiavvio).'
} else {
    Write-Host 'Il PC si riavvia tra 30 secondi per completare la configurazione.' -ForegroundColor Yellow
    & shutdown.exe /r /t 30 /c 'Configurazione del carrello completata: riavvio'
}
