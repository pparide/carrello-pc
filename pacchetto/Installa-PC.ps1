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
    5. Policy per Chrome ed Edge, OneDrive spento, niente schermate di primo accesso.
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
$TaskName    = 'Carrello-Logon'
$UpdTaskName = 'Carrello-Aggiorna'
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
        New-ItemProperty -LiteralPath $full -Name $Name -PropertyType $Type -Value $Value -Force | Out-Null
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
               Where-Object { $_.Name -ne 'desktop.ini' -and $_.Name -ne 'Lavori.lnk' })
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
              'WindowsTerminal.exe', 'wt.exe', 'wsl.exe', 'mmc.exe'

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
Add-MP 'SOFTWARE\Policies\Microsoft\Dsh' 'AllowNewsAndInterests' 'DWord' 0
Add-MP 'SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' 'EnableFirstLogonAnimation' 'DWord' 0
Add-MP 'SOFTWARE\Microsoft\WindowsUpdate\UX\Settings' 'ActiveHoursStart' 'DWord' 7
Add-MP 'SOFTWARE\Microsoft\WindowsUpdate\UX\Settings' 'ActiveHoursEnd' 'DWord' 19
Add-MP 'SOFTWARE\Microsoft\WindowsUpdate\UX\Settings' 'SmartActiveHoursState' 'DWord' 2
Add-MP 'SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' 'NoAutoRebootWithLoggedOnUsers' 'DWord' 1
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

function New-StudentProfile([string]$sid) {
    if ($Simula) { Write-Log '[SIMULAZIONE] creerei il profilo di Studente'; return }
    try {
        Add-Type -Namespace Carrello -Name Profilo -MemberDefinition @'
[DllImport("userenv.dll", CharSet=CharSet.Unicode)]
public static extern int CreateProfile(string pszUserSid, string pszUserName, System.Text.StringBuilder pszProfilePath, uint cchProfilePath);
'@ -ErrorAction Stop
        $sb = New-Object System.Text.StringBuilder 260
        $hr = [Carrello.Profilo]::CreateProfile($sid, $StudentName, $sb, 260)
        Write-Log ("Creazione profilo di Studente: esito 0x{0:X}" -f $hr)
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
        # etichetta in alto a destra
        $font = New-Object System.Drawing.Font('Segoe UI', 72, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
        $size = $g.MeasureString($label, $font)
        $padX = 36; $padY = 14
        $bw = $size.Width + 2 * $padX; $bh = $size.Height + 2 * $padY
        $bx = $w - $bw - 40; $by = 40
        $brush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(150, 10, 20, 40))
        $g.FillRectangle($brush, [single]$bx, [single]$by, [single]$bw, [single]$bh)
        $g.DrawString($label, $font, [System.Drawing.Brushes]::White, [single]($bx + $padX), [single]($by + $padY))
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

# barra delle applicazioni: Word, Excel, GeoGebra, Chrome, Calcolatrice, Scratch (solo quelli installati)
function New-TaskbarLayout {
    if ($Simula) { Write-Log '[SIMULAZIONE] creerei il layout della barra delle applicazioni'; return }
    $sm = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs'
    $pins = New-Object System.Collections.Generic.List[string]
    $startPins = New-Object System.Collections.Generic.List[object]
    foreach ($pat in 'Word.lnk', 'Excel.lnk', 'GeoGebra*.lnk', 'Google Chrome.lnk', '#CALC#', 'Scratch*.lnk') {
        if ($pat -eq '#CALC#') {
            if (Get-AppxPackage -AllUsers -Name 'Microsoft.WindowsCalculator' -ErrorAction SilentlyContinue) {
                $pins.Add('        <taskbar:UWA AppUserModelID="Microsoft.WindowsCalculator_8wekyb3d8bbwe!App" />')
                $startPins.Add(@{ packagedAppId = 'Microsoft.WindowsCalculator_8wekyb3d8bbwe!App' })
            }
            continue
        }
        $f = Get-ChildItem -LiteralPath $sm -Recurse -Filter $pat -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($f) {
            $pins.Add(('        <taskbar:DesktopApp DesktopApplicationLinkPath="{0}" />' -f $f.FullName))
            $startPins.Add(@{ desktopAppLink = $f.FullName.Replace($env:ProgramData, '%ALLUSERSPROFILE%') })
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
    Set-Content -LiteralPath $TaskbarXml -Value ($lines -join "`r`n") -Encoding UTF8
    $script:StartPinsJson = (@{ pinnedList = @($startPins) } | ConvertTo-Json -Depth 4)
    Write-Log ("Layout della barra e di Start creato ({0} icone)" -f $pins.Count)
}

# il layout di Start e della barra si applica al PRIMO accesso di un profilo nuovo, partendo dal profilo Default
function Set-DefaultLayout {
    if ($Simula) { Write-Log '[SIMULAZIONE] metterei il layout di Start e barra nel profilo Default'; return }
    try {
        $shell = 'C:\Users\Default\AppData\Local\Microsoft\Windows\Shell'
        New-Item -ItemType Directory -Path $shell -Force | Out-Null
        Copy-Item -LiteralPath $TaskbarXml -Destination (Join-Path $shell 'LayoutModification.xml') -Force
        if ($script:StartPinsJson) { Set-Content -LiteralPath (Join-Path $shell 'LayoutModification.json') -Value $script:StartPinsJson -Encoding UTF8 }
    } catch { Write-Log "Layout nel profilo Default non scritto: $($_.Exception.Message)" 'AVVISO' }
}
function Clear-DefaultLayout {
    if ($Simula) { return }
    $shell = 'C:\Users\Default\AppData\Local\Microsoft\Windows\Shell'
    Remove-Item -LiteralPath (Join-Path $shell 'LayoutModification.xml') -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $shell 'LayoutModification.json') -Force -ErrorAction SilentlyContinue
}

function Set-MachineConfig {
    foreach ($p in $MachinePolicies) { Set-RegValue $HKLM $p.P $p.N $p.T $p.V }
}
function Remove-MachineConfig {
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
        $t2 = New-ScheduledTaskTrigger -Daily -At '12:30'
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

function Remove-StoreApp([string]$name) {
    Get-AppxPackage -AllUsers -Name $name -ErrorAction SilentlyContinue | Remove-AppxPackage -AllUsers -ErrorAction SilentlyContinue
    Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -eq $name } |
        Remove-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Out-Null
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
            Move-ToBackup "$prof\Desktop" 'Desktop'
            Move-ToBackup "$prof\Downloads" 'Download'
            try {
                $ws  = New-Object -ComObject WScript.Shell
                $lnk = $ws.CreateShortcut("$prof\Desktop\Lavori.lnk")
                $lnk.TargetPath = $LavoriDir
                $lnk.Save()
            } catch { }
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

Write-Host ''
Write-Host "Installa-PC v$Versione" -ForegroundColor Cyan
if ($Simula) { Write-Host 'MODALITA SIMULAZIONE: non viene modificato nulla.' -ForegroundColor Yellow }

# ======================================================== ANNULLA
if ($Annulla) {
    Write-Log 'ANNULLA: inizio'
    Remove-LogonTask
    Remove-UpdateTask
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
if (-not $Carrello) { $Carrello = [int](Read-Host 'Numero del carrello (1 o 2)') }
if (-not $NumeroPC) { $NumeroPC = [int](Read-Host 'Numero del PC (numero d''appello)') }
if ($Carrello -lt 1 -or $Carrello -gt 9 -or $NumeroPC -lt 1 -or $NumeroPC -gt 99) { Write-Host 'Numeri non validi.' -ForegroundColor Red; exit 1 }
$newName = 'C{0}-{1:00}' -f $Carrello, $NumeroPC

Write-Host ''
Write-Host "Questo PC diventa: $newName" -ForegroundColor Cyan
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
    foreach ($f in 'Aggiorna-PC.ps1', 'ElencoApp-da-rimuovere.txt', 'ElencoProgrammi-da-rimuovere.txt') {
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
    try { Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction Stop; Checkpoint-Computer -Description 'Prima di Installa-PC' -RestorePointType MODIFY_SETTINGS -ErrorAction Stop; Write-Log 'Punto di ripristino creato' }
    catch { Write-Log "Punto di ripristino non creato: $($_.Exception.Message)" 'AVVISO' }
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
    }
    Write-Log "Account $AdminName gia' presente: password invariata"
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
}

# --- sfondo con il numero del PC
New-WallpaperImage $WallFile $newName $Carrello
Install-GeoGebra
New-TaskbarLayout
Set-DefaultLayout

# --- impostazioni di sistema
Set-MachineConfig
Set-Autologon
if ($ConBloccoProgrammi) { Set-Srp } else { Remove-Srp }

# --- impostazioni di Studente
$sid = if ($stu) { $stu.SID.Value } else { 'S-1-5-21-SIMULATO' }
$done = Use-UserHive $sid { param($root) Set-UserConfig $root }
if (-not $done) {
    New-StudentProfile $sid
    $done = Use-UserHive $sid { param($root) Set-UserConfig $root }
}
if (-not $done) { Write-Log 'Profilo di Studente non disponibile: i blocchi saranno scritti al primo accesso' 'AVVISO' }
Clear-DefaultLayout
Set-LogonTask
if (-not $Aggiorna) { Set-UpdateTask }

# --- gestione remota e Wi-Fi
Enable-RemoteAccess
Set-WifiAuto

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

# ======================================================== riepilogo
if ($Aggiorna) { Write-Log "Aggiornamento di configurazione applicato (script v$Versione)"; exit 0 }
Write-Host ''
if ($Simula) {
    Write-Host "SIMULAZIONE FINITA. Risultato nel file: $SimLog" -ForegroundColor Green
    exit 0
}
Write-Host '=== FATTO ===' -ForegroundColor Green
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
