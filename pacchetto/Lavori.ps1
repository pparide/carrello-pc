<#
.SYNOPSIS
  Cartella Lavori dei carrelli: scelta della classe, copia di sicurezza giornaliera e registro delle modifiche.

.DESCRIPTION
  -Imposta   (SYSTEM, in installazione e in aggiornamento) attiva il controllo degli accessi ai file di C:\Lavori
             (audit di Windows) e la dimensione del registro di sicurezza.
  -Snapshot  (SYSTEM, a ogni accesso di Studente) copia C:\Lavori in C:\Backup-Carrello\Lavori-Giornaliero\<data>
             (una al giorno, 30 giorni) ed esporta in Registro-Lavori.csv le modifiche fatte ai file.
  -Ascolta   (SYSTEM, sempre in esecuzione) i PC dello stesso carrello si scambiano la classe scelta (messaggi UDP sulla rete
             locale, porta 47010): se nel carrello ci sono classi diverse nello stesso momento lo scrive nel registro e la
             finestra di scelta della classe avvisa.
  -Classe    (Studente, a ogni accesso) mostra la scelta della classe: crea C:\Lavori\<classe>, la lega al collegamento
             "Lavori" del desktop. Le classi sono in Classi.txt (una per riga).
#>
param([switch]$Imposta, [switch]$Snapshot, [switch]$Classe, [switch]$Ascolta)

$ErrorActionPreference = 'Continue'
$Base      = Join-Path $env:ProgramData 'GestioneCarrello'
$LavoriDir = 'C:\Lavori'
$BackupDir = 'C:\Backup-Carrello'
$LogFile   = Join-Path $Base 'log.txt'
$CsvFile   = Join-Path $Base 'Registro-Lavori.csv'
$LastFile  = Join-Path $Base 'registro-ultimo.txt'
$PeersFile = Join-Path $Base 'classi-carrello.json'
$UdpPort   = 47010

function Write-Log([string]$msg, [string]$level = 'INFO') {
    try { Add-Content -Path $LogFile -Value ('{0} [{1}] LAVORI: {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $level, $msg) -Encoding UTF8 } catch { }
}

# ---------------------------------------------------------------- Ascolta
if ($Ascolta) {
    if ($env:COMPUTERNAME -notmatch '^C(\d)-(\d{2})$') { exit 0 }
    $cart = $Matches[1]
    $me = $env:COMPUTERNAME
    $udp = $null
    try {
        $udp = New-Object System.Net.Sockets.UdpClient
        $udp.Client.SetSocketOption('Socket', 'ReuseAddress', $true)
        $udp.Client.Bind((New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, $UdpPort)))
        $udp.EnableBroadcast = $true
        $udp.Client.ReceiveTimeout = 5000
    } catch { Write-Log "Scambio delle classi non avviato: $($_.Exception.Message)" 'AVVISO'; exit 1 }
    $dest = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Broadcast, $UdpPort)
    $peers = @{}
    $lastSend = [datetime]::MinValue; $lastConf = ''
    $sidStud = (Get-LocalUser -Name 'Studente' -ErrorAction SilentlyContinue).SID.Value
    while ($true) {
        $now = Get-Date
        # classe di questo PC (scelta da Studente, tenuta nel suo registro)
        $mia = $null
        if ($sidStud -and (Test-Path "Registry::HKEY_USERS\$sidStud\Software\Carrello")) {
            $mia = (Get-ItemProperty "Registry::HKEY_USERS\$sidStud\Software\Carrello" -ErrorAction SilentlyContinue).Classe
        }
        if ($mia -and $mia -ne 'Altro') { $peers[$me] = @{ classe = $mia; t = $now } } else { $peers.Remove($me) }
        if ($mia -and $mia -ne 'Altro' -and ($now - $lastSend).TotalSeconds -ge 60) {
            try { $b = [Text.Encoding]::UTF8.GetBytes((@{ pc = $me; classe = $mia } | ConvertTo-Json -Compress)); [void]$udp.Send($b, $b.Length, $dest) } catch { }
            $lastSend = $now
        }
        try {
            $ep = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
            $data = $udp.Receive([ref]$ep)
            $m = [Text.Encoding]::UTF8.GetString($data) | ConvertFrom-Json
            if ($m.pc -match '^C\d-\d{2}$' -and $m.pc -ne $me -and $m.classe) { $peers[[string]$m.pc] = @{ classe = [string]$m.classe; t = (Get-Date) } }
        } catch { }
        # scadenza: dopo 5 minuti senza segnali il PC non conta piu'
        foreach ($k in @($peers.Keys)) { if (($now - $peers[$k].t).TotalMinutes -gt 5) { $peers.Remove($k) } }
        # classi attive in questo carrello
        $att = @{}
        foreach ($k in $peers.Keys) { if ($k -like "C$cart-*") { $c = $peers[$k].classe; if (-not $att.ContainsKey($c)) { $att[$c] = @() }; $att[$c] += $k } }
        try {
            $json = @{ aggiornato = $now.ToString('yyyy-MM-dd HH:mm:ss'); carrello = [int]$cart; classi = @($att.Keys | ForEach-Object { @{ classe = $_; pc = @($att[$_]) } }) } | ConvertTo-Json -Depth 5 -Compress
            Set-Content -LiteralPath $PeersFile -Value $json -Encoding UTF8
        } catch { }
        $desc = (($att.Keys | Sort-Object | ForEach-Object { "$_ ($($att[$_].Count) PC)" }) -join ', ')
        if ($att.Count -gt 1 -and $desc -ne $lastConf) {
            $lastConf = $desc
            try {
                if (-not (Test-Path -LiteralPath $CsvFile)) { Set-Content -LiteralPath $CsvFile -Value 'Ora;PC;Classe;Azione;File;Programma' -Encoding UTF8 }
                Add-Content -LiteralPath $CsvFile -Value ('{0};{1};{2};{3};{4};{5}' -f $now.ToString('yyyy-MM-dd HH:mm:ss'), $me, '', 'CLASSI DIVERSE NEL CARRELLO', $desc, '') -Encoding UTF8
            } catch { }
            Write-Log "Classi diverse nello stesso carrello: $desc" 'AVVISO'
        } elseif ($att.Count -le 1) { $lastConf = '' }
    }
}

# ---------------------------------------------------------------- Imposta
if ($Imposta) {
    try {
        if (-not (Test-Path -LiteralPath $LavoriDir)) { New-Item -ItemType Directory -Path $LavoriDir -Force | Out-Null }
        # sottocategoria "File system" (con il suo identificatore, valido in tutte le lingue)
        & auditpol.exe /set /subcategory:"{0CCE921D-69AE-11D9-BED3-505054503030}" /success:enable | Out-Null
        & wevtutil.exe sl Security /ms:209715200 | Out-Null
        $acl = Get-Acl -LiteralPath $LavoriDir -Audit
        $rights = [System.Security.AccessControl.FileSystemRights]'Delete, DeleteSubdirectoriesAndFiles, WriteData, AppendData, CreateFiles'
        $rule = New-Object System.Security.AccessControl.FileSystemAuditRule('Everyone', $rights, 'ContainerInherit, ObjectInherit', 'None', 'Success')
        $acl.AddAuditRule($rule)
        Set-Acl -LiteralPath $LavoriDir -AclObject $acl
        Write-Log 'Registro delle modifiche in C:\Lavori attivo (audit dei file)'
    } catch { Write-Log "Registro delle modifiche non attivato: $($_.Exception.Message)" 'AVVISO' }
    exit 0
}

# ---------------------------------------------------------------- Snapshot
if ($Snapshot) {
    # 1. copia di sicurezza giornaliera
    try {
        if (Test-Path -LiteralPath $LavoriDir) {
            $root = Join-Path $BackupDir 'Lavori-Giornaliero'
            $dst  = Join-Path $root (Get-Date -Format 'yyyyMMdd')
            if (-not (Test-Path -LiteralPath $dst)) {
                if (-not (Test-Path -LiteralPath $BackupDir)) { New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null }
                New-Item -ItemType Directory -Path $dst -Force | Out-Null
                & icacls.exe $BackupDir /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
                & robocopy.exe $LavoriDir $dst /E /COPY:DAT /R:1 /W:1 /XJ /NFL /NDL /NP /NJH /NJS | Out-Null
                Write-Log "Copia giornaliera di C:\Lavori in $dst"
                Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue |
                    Where-Object { $_.CreationTime -lt (Get-Date).AddDays(-30) } | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    } catch { Write-Log "Copia giornaliera non riuscita: $($_.Exception.Message)" 'AVVISO' }

    # 2. registro delle modifiche (eventi 4663 del registro di sicurezza)
    try {
        $since = (Get-Date).AddDays(-1)
        if (Test-Path -LiteralPath $LastFile) { try { $since = [datetime]::Parse((Get-Content -LiteralPath $LastFile -Raw).Trim(), [Globalization.CultureInfo]::InvariantCulture) } catch { } }
        $now = Get-Date
        $events = @(Get-WinEvent -FilterHashtable @{ LogName = 'Security'; Id = 4663; StartTime = $since } -ErrorAction SilentlyContinue)
        $rows = New-Object System.Collections.Generic.List[string]
        foreach ($ev in $events) {
            $x = [xml]$ev.ToXml()
            $d = @{}
            foreach ($n in $x.Event.EventData.Data) { $d[$n.Name] = $n.'#text' }
            $obj = $d['ObjectName']
            if (-not $obj -or $obj -notlike 'C:\Lavori\*') { continue }
            $leaf = Split-Path $obj -Leaf
            if ($leaf -like '~$*' -or $leaf -like '*.tmp' -or $leaf -like '.~lock*' -or $leaf -like '*.crdownload') { continue }
            $mask = 0; try { $mask = [Convert]::ToInt32(($d['AccessMask'] -replace '^0x', ''), 16) } catch { }
            $act = if ($mask -band 0x10000) { 'ELIMINATO/RINOMINATO' } elseif ($mask -band 0x6) { 'CREATO/MODIFICATO' } else { continue }
            $rel = $obj.Substring('C:\Lavori\'.Length)
            $cls = if ($rel.Contains('\')) { $rel.Split('\')[0] } else { '' }
            $proc = Split-Path ([string]$d['ProcessName']) -Leaf
            $rows.Add(('{0};{1};{2};{3};{4};{5}' -f $ev.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss'), $env:COMPUTERNAME, $cls, $act, $obj, $proc))
        }
        if ($rows.Count -gt 0) {
            if (-not (Test-Path -LiteralPath $CsvFile)) { Set-Content -LiteralPath $CsvFile -Value 'Ora;PC;Classe;Azione;File;Programma' -Encoding UTF8 }
            Add-Content -LiteralPath $CsvFile -Value ($rows | Sort-Object -Unique) -Encoding UTF8
        }
        Set-Content -LiteralPath $LastFile -Value $now.ToString('yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture) -Encoding ascii
        if ($rows.Count -gt 0) { Write-Log ("Registro modifiche: {0} voci aggiunte a Registro-Lavori.csv" -f $rows.Count) }
    } catch { Write-Log "Registro modifiche non esportato: $($_.Exception.Message)" 'AVVISO' }
    exit 0
}

# ---------------------------------------------------------------- Classe (utente Studente)
if ($Classe) {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    # una sola finestra alla volta
    $mx = New-Object System.Threading.Mutex($false, 'Local\CarrelloClasse')
    if (-not $mx.WaitOne(0)) { exit 0 }
    # a ogni nuovo accesso (o a ogni "Cambia classe") la scelta precedente si azzera
    Remove-ItemProperty -Path 'HKCU:\Software\Carrello' -Name 'Classe', 'ClasseOra' -ErrorAction SilentlyContinue
    $file = Join-Path $Base 'Classi.txt'
    $classi = @()
    if (Test-Path -LiteralPath $file) {
        $classi = @(Get-Content -LiteralPath $file -Encoding UTF8 | ForEach-Object { ($_ -replace '#.*$', '').Trim() } | Where-Object { $_ })
    }
    if ($classi.Count -eq 0) { exit 0 }
    $classi = $classi + 'Altro'

    # classi gia' in uso dagli altri PC dello stesso carrello (ricevute via rete)
    $script:altre = @{}
    try {
        $pf = Join-Path $Base 'classi-carrello.json'
        if ((Test-Path -LiteralPath $pf) -and ((Get-Date) - (Get-Item -LiteralPath $pf).LastWriteTime).TotalMinutes -lt 3) {
            foreach ($c in ((Get-Content -LiteralPath $pf -Raw -Encoding UTF8 | ConvertFrom-Json).classi)) { $script:altre[[string]$c.classe] = @($c.pc).Count }
        }
    } catch { }

    # finestra a tutto schermo, sempre in primo piano: senza scegliere la classe il PC non si usa
    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'Scegli la tua classe'
    $form.FormBorderStyle = 'None'
    $form.StartPosition = 'Manual'
    $form.Bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $form.TopMost = $true
    $form.ShowInTaskbar = $false
    $form.BackColor = [System.Drawing.Color]::FromArgb(24, 44, 78)

    $corte = @($classi | Where-Object { $_.Length -le 5 })
    $lunghe = @($classi | Where-Object { $_.Length -gt 5 })
    $cols = 7; $bw = 100; $bh = 56; $gap = 10
    $pw = $cols * ($bw + $gap) + $gap
    $righe = [math]::Ceiling($corte.Count / $cols)
    $ph = 150 + $righe * ($bh + $gap) + $lunghe.Count * ($bh + $gap) + 20
    $panel = New-Object System.Windows.Forms.Panel
    $panel.BackColor = [System.Drawing.Color]::White
    $panel.Size = New-Object System.Drawing.Size($pw, $ph)
    $panel.Location = New-Object System.Drawing.Point([int](($form.Width - $pw) / 2), [int](($form.Height - $ph) / 2))
    $form.Controls.Add($panel)

    $t1 = New-Object System.Windows.Forms.Label
    $t1.Text = 'Che classe siete?'
    $t1.Font = New-Object System.Drawing.Font('Segoe UI', 22, [System.Drawing.FontStyle]::Bold)
    $t1.AutoSize = $true; $t1.Location = New-Object System.Drawing.Point(14, 12)
    $panel.Controls.Add($t1)
    $t2 = New-Object System.Windows.Forms.Label
    $t2.Text = "Clicca la tua classe per usare il PC: il collegamento Lavori si apre sulla cartella della classe.`r`nATTENZIONE: tutte le modifiche ai file in Lavori sono REGISTRATE (PC, classe, ora)."
    $t2.Font = New-Object System.Drawing.Font('Segoe UI', 11)
    $t2.AutoSize = $true; $t2.Location = New-Object System.Drawing.Point(16, 62)
    $panel.Controls.Add($t2)

    $script:scelta = $null
    $clic = {
        param($s, $e)
        $c = [string]$s.Tag
        $diverse = @($script:altre.Keys | Where-Object { $_ -ne $c })
        if ($c -ne 'Altro' -and $diverse.Count -gt 0) {
            $txt = "In questo carrello ci sono GIA' PC accesi della classe: " + (($diverse | Sort-Object) -join ', ') + ".`r`n`r`nVuoi davvero scegliere la classe $c ? (La scelta viene registrata.)"
            $r = [System.Windows.Forms.MessageBox]::Show($form, $txt, 'Attenzione: classi diverse nel carrello', 'YesNo', 'Warning')
            if ($r -ne 'Yes') { return }
        }
        $script:scelta = $c
        $form.Close()
    }
    $i = 0
    foreach ($c in $corte) {
        $b = New-Object System.Windows.Forms.Button
        $b.Text = $c
        $b.Font = New-Object System.Drawing.Font('Segoe UI', 14, [System.Drawing.FontStyle]::Bold)
        $b.Size = New-Object System.Drawing.Size($bw, $bh)
        $b.Location = New-Object System.Drawing.Point(($gap + ($i % $cols) * ($bw + $gap)), (120 + [math]::Floor($i / $cols) * ($bh + $gap)))
        $b.Tag = $c
        $b.Add_Click($clic)
        $panel.Controls.Add($b)
        $i++
    }
    $y = 120 + $righe * ($bh + $gap)
    foreach ($c in $lunghe) {
        $b = New-Object System.Windows.Forms.Button
        $b.Text = $c
        $b.Font = New-Object System.Drawing.Font('Segoe UI', 14, [System.Drawing.FontStyle]::Bold)
        $b.Size = New-Object System.Drawing.Size(($pw - 2 * $gap), $bh)
        $b.Location = New-Object System.Drawing.Point($gap, $y)
        $b.Tag = $c
        $b.Add_Click($clic)
        $panel.Controls.Add($b)
        $y += $bh + $gap
    }
    # non si chiude senza una scelta (neanche con Alt+F4) e resta sopra tutto
    $form.Add_FormClosing({ param($s, $e) if (-not $script:scelta) { $e.Cancel = $true } })
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 800
    $script:tick = 0
    $timer.Add_Tick({
        $script:tick++
        $form.TopMost = $true; $form.Activate(); $form.BringToFront()
        # all'accensione il menu Start puo' restare aperto sopra la finestra: nei primi secondi si chiude con Esc (e con un clic sul pannello)
        if ($script:tick -in 2, 4, 7, 11) { try { [System.Windows.Forms.SendKeys]::SendWait('{ESC}') } catch { } }
    })
    $timer.Start()
    [void]$form.ShowDialog()
    $timer.Stop()
    if (-not $script:scelta) { exit 0 }

    $cartella = Join-Path $LavoriDir $script:scelta
    try {
        if (-not (Test-Path -LiteralPath $cartella)) { New-Item -ItemType Directory -Path $cartella -Force | Out-Null }
        # la cartella della classe diventa il disco L: (da L: non si risale alle cartelle delle altre classi)
        & subst.exe L: /d 2>$null | Out-Null
        & subst.exe L: $cartella 2>$null | Out-Null
        $bersaglio = if (Test-Path -LiteralPath 'L:\') { 'L:\' } else { $cartella }
        New-Item -Path 'HKCU:\Software\Classes\Applications\Explorer.exe\Drives\L' -Force | Out-Null
        Set-ItemProperty -Path 'HKCU:\Software\Classes\Applications\Explorer.exe\Drives\L' -Name 'DefaultLabel' -Value ('Lavori ' + $script:scelta)
        $desk = [Environment]::GetFolderPath('Desktop')
        $ws = New-Object -ComObject WScript.Shell
        $lnk = $ws.CreateShortcut((Join-Path $desk 'Lavori.lnk'))
        $lnk.TargetPath = $bersaglio
        $lnk.Save()
        New-Item -Path 'HKCU:\Software\Carrello' -Force | Out-Null
        Set-ItemProperty -Path 'HKCU:\Software\Carrello' -Name 'Classe' -Value $script:scelta
        Set-ItemProperty -Path 'HKCU:\Software\Carrello' -Name 'ClasseOra' -Value (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    } catch { }
    exit 0
}
