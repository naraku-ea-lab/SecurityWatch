# SecurityWatch  -  PCの「勝手な変化」「外からのログイン」に気づくための、無料の見守りツール（1ファイルで完結）
#  使い方: SecurityWatch.cmd をダブルクリック →「はい」でインストール /「いいえ」で削除。
#  このファイルの中身は、すべて読めます。通知は、あなた自身の Discord だけに送ります（作者には、何も送られません）。
#  免責: 入られるのを防ぐものではなく、変化に気づくための道具です。動作・効果・安全性を、保証しません。
param(
    [ValidateSet('Menu','Install','Uninstall','Watch','Logon')][string]$Mode = 'Menu',
    [string]$InstallDir = (Join-Path $env:ProgramData 'SecurityWatch'),
    [switch]$DryRun, [switch]$Heartbeat, [switch]$NoSystemChanges, [switch]$NoTasks, [switch]$Test
)

function Invoke-Watch {
    param([switch]$DryRun, [switch]$Heartbeat)

$dir   = $PSScriptRoot
$state = Join-Path $dir 'baseline.json'
$log   = Join-Path $dir 'alerts.log'
$hookF = Join-Path $dir 'webhook.txt'
$hbF   = Join-Path $dir 'heartbeat.txt'

function Get-Snapshot {
    $s = [ordered]@{}
    # 1. 自動起動（Run キー）
    $runs = @()
    foreach ($k in 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run','HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce',
                   'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run','HKLM:\Software\Microsoft\Windows\CurrentVersion\RunOnce',
                   'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run') {
        if (Test-Path $k) {
            (Get-ItemProperty $k).PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' } |
                ForEach-Object { $runs += ("{0} | {1} = {2}" -f ($k -replace 'Microsoft\\Windows\\CurrentVersion\\',''), $_.Name, $_.Value) }
        }
    }
    $s.run = @($runs | Sort-Object)
    # 2. スタートアップフォルダ
    $st = @()
    foreach ($d in "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup", 'C:\ProgramData\Microsoft\Windows\Start Menu\Programs\StartUp') {
        if (Test-Path $d) { Get-ChildItem $d -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'desktop.ini' } | ForEach-Object { $st += ("{0} ({1:yyyy/MM/dd HH:mm})" -f $_.FullName, $_.LastWriteTime) } }
    }
    $s.startup = @($st | Sort-Object)
    # 3. スケジュールタスク（Microsoft 以外）
    $tk = @()
    Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskPath -notmatch '^\\Microsoft\\' } | ForEach-Object {
        $a = ($_.Actions | ForEach-Object { "$($_.Execute) $($_.Arguments)" }) -join ' ; '
        $tk += ("{0}{1} => {2}" -f $_.TaskPath, $_.TaskName, $a)
    }
    $s.tasks = @($tk | Sort-Object)
    # 4. サービス（Windows 標準の場所以外）
    $sv = @()
    Get-CimInstance Win32_Service -ErrorAction SilentlyContinue | Where-Object { $_.PathName -and $_.PathName -notmatch '^"?C:\\Windows\\' } |
        ForEach-Object { $sv += ("{0} | {1} | {2}" -f $_.Name, $_.PathName, $_.StartMode) }
    $s.services = @($sv | Sort-Object)
    # 5. ユーザーと管理者グループ
    $s.users  = @(Get-LocalUser -ErrorAction SilentlyContinue | ForEach-Object { "{0} enabled={1}" -f $_.Name, $_.Enabled } | Sort-Object)
    $adm = @(); try { $adm = @((net localgroup Administrators 2>$null) | Where-Object { $_ -and $_ -notmatch '^(Alias|Comment|Members|エイリアス|コメント|メンバー|---|The command|コマンド)' }) } catch {}
    $s.admins = @($adm | Sort-Object)
    # 6. 外からの接続を受け付けるポート（待ち受け）
    $ls = @()
    Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Where-Object { $_.LocalAddress -notin '127.0.0.1','::1' } | ForEach-Object {
        $pn = (Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue).ProcessName
        $ls += ("{0} ({1})" -f $_.LocalPort, $pn)
    }
    $s.listen = @($ls | Sort-Object -Unique)
    # 7. リモート操作ソフトの有無（動作中）
    $s.remote = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match '^(remoting_host|anydesk|teamviewer|rustdesk|ultraviewer|ammyy|supremo|vnc|tvnserver|winvnc|screenconnect|rdpclip)' } | ForEach-Object { $_.ProcessName } | Sort-Object -Unique)
    return $s
}

function Send-Alert([string]$text) {
    $line = "{0:yyyy/MM/dd HH:mm:ss} {1}" -f (Get-Date), $text
    if ($DryRun) { Write-Output "[通知(ドライラン)] $text"; return }
    Add-Content -Path $log -Value $line -Encoding UTF8
    if (Test-Path $hookF) {
        $url = (Get-Content $hookF -Raw).Trim()
        if ($url -match '^https://(discord|discordapp)\.com/api/webhooks/') {
            try {
                $body = @{ content = $text.Substring(0, [Math]::Min(1900, $text.Length)) } | ConvertTo-Json
                Invoke-RestMethod -Uri $url -Method Post -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($body)) | Out-Null
            } catch { Add-Content -Path $log -Value ("{0:yyyy/MM/dd HH:mm:ss} (Discord送信失敗: {1})" -f (Get-Date), $_.Exception.Message) -Encoding UTF8 }
        }
    }
}

$now = Get-Snapshot
$labels = @{ run='自動起動(Runキー)'; startup='スタートアップ'; tasks='スケジュールタスク'; services='サービス'; users='ユーザー'; admins='管理者グループ'; listen='待ち受けポート'; remote='リモート操作ソフト' }

if (-not (Test-Path $state)) {
    if (-not $DryRun) { $now | ConvertTo-Json -Depth 5 | Set-Content -Path $state -Encoding UTF8 }
    $msg = "SecurityWatch: 基準を保存しました（" + (($now.Keys | ForEach-Object { "$($labels[$_]) $(@($now[$_]).Count)件" }) -join ' / ') + "）"
    if ($DryRun) { Write-Output $msg } else { Send-Alert "🟢 $msg" }
} else {
    $base = Get-Content $state -Raw | ConvertFrom-Json
    $changes = @()
    foreach ($k in $now.Keys) {
        $old = @($base.$k); $new = @($now[$k])
        $added = @($new | Where-Object { $_ -notin $old })
        $gone  = @($old | Where-Object { $_ -notin $new })
        foreach ($a in $added) { $changes += "➕ [$($labels[$k])] 増えました: $a" }
        if ($k -in 'users','admins','tasks','services','run','startup') { foreach ($g in $gone) { $changes += "➖ [$($labels[$k])] 消えました: $g" } }
    }
    # リモートデスクトップのセッション（接続中）
    $q = @(); try { $q = @((qwinsta 2>$null) | Where-Object { $_ -match 'Active|アクティブ' -and $_ -notmatch 'console|コンソール' }) } catch {}
    foreach ($x in $q) { $changes += "🔴 [リモート接続中] $($x.Trim())" }
    # Defender の保護
    try { $mp = Get-MpComputerStatus; if (-not $mp.RealTimeProtectionEnabled) { $changes += "🔴 [Defender] リアルタイム保護が OFF です" }; if ($mp.AntivirusSignatureAge -gt 3) { $changes += "🟠 [Defender] ウイルス定義が $($mp.AntivirusSignatureAge) 日更新されていません" } } catch {}
    if ($changes.Count -gt 0) {
        Send-Alert ("⚠️ SecurityWatch（$env:COMPUTERNAME）`n" + ($changes -join "`n"))
        if (-not $DryRun) { $now | ConvertTo-Json -Depth 5 | Set-Content -Path $state -Encoding UTF8 }   # 通知したら基準を更新（同じ通知を繰り返さない）
    } elseif ($DryRun) { Write-Output "変更なし（基準と同じ）" }
}

# 生存確認（1日1回）
$today = (Get-Date).ToString('yyyyMMdd')
if (-not $DryRun -and ((-not (Test-Path $hbF)) -or ((Get-Content $hbF -ErrorAction SilentlyContinue) -ne $today)) -and (Get-Date).Hour -ge 9) {
    Set-Content -Path $hbF -Value $today
    Send-Alert "🟢 SecurityWatch は動いています（$env:COMPUTERNAME $today）"
}

}

function Invoke-Logon {
    param([switch]$DryRun)

$dir    = $PSScriptRoot
$lastF  = Join-Path $dir 'logon_last.txt'
$log    = Join-Path $dir 'alerts.log'
$hookF  = Join-Path $dir 'webhook.txt'

function Send-Alert([string]$text) {
    if ($DryRun) { Write-Output "[通知(ドライラン)] $text"; return }
    Add-Content -Path $log -Value ("{0:yyyy/MM/dd HH:mm:ss} {1}" -f (Get-Date), $text) -Encoding UTF8
    if (Test-Path $hookF) {
        $url = (Get-Content $hookF -Raw).Trim()
        if ($url -match '^https://(discord|discordapp)\.com/api/webhooks/') {
            try {
                $body = @{ content = $text.Substring(0, [Math]::Min(1900, $text.Length)) } | ConvertTo-Json
                Invoke-RestMethod -Uri $url -Method Post -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($body)) | Out-Null
            } catch { Add-Content -Path $log -Value ("{0:yyyy/MM/dd HH:mm:ss} (Discord送信失敗: {1})" -f (Get-Date), $_.Exception.Message) -Encoding UTF8 }
        }
    }
}

function Get-Data($e) { $x = [xml]$e.ToXml(); $d = @{}; foreach ($n in $x.Event.EventData.Data) { $d[$n.Name] = $n.'#text' }; $d }

$now   = Get-Date
$since = $now.AddMinutes(-6)
if (Test-Path $lastF) { try { $since = [datetime]::Parse((Get-Content $lastF -Raw).Trim()).AddSeconds(-5) } catch {} }
else { if (-not $DryRun) { Set-Content -Path $lastF -Value $now.ToString('o'); Send-Alert "🟢 SecurityWatchLogon を開始しました（外からのログイン・失敗・新しいユーザーを見守ります）"; return } }

$lines = New-Object System.Collections.Generic.List[string]

# 1) ログイン成功：ネットワーク(3)・リモートデスクトップ(10)で、接続元が自分以外
try {
    Get-WinEvent -FilterHashtable @{LogName='Security'; Id=4624; StartTime=$since} -ErrorAction Stop | ForEach-Object {
        $d = Get-Data $_
        if ($d.LogonType -in '3','10' -and $d.IpAddress -and $d.IpAddress -notin '-','::1','127.0.0.1' -and $d.TargetUserName -notmatch '\$$|ANONYMOUS') {
            $lines.Add(("🔴 外からのログイン成功: {0:MM/dd HH:mm:ss} 種類{1}({2}) ユーザー={3} 接続元={4}" -f $_.TimeCreated, $d.LogonType, $(if($d.LogonType -eq '10'){'リモートデスクトップ'}else{'ネットワーク'}), $d.TargetUserName, $d.IpAddress))
        }
    }
} catch {}

# 2) ログイン失敗：3回以上（接続元ごと）、または外からの失敗
try {
    $f = @(Get-WinEvent -FilterHashtable @{LogName='Security'; Id=4625; StartTime=$since} -ErrorAction Stop | ForEach-Object { $d = Get-Data $_; [pscustomobject]@{IP=$d.IpAddress; User=$d.TargetUserName; Type=$d.LogonType} })
    $ext = @($f | Where-Object { $_.IP -and $_.IP -notin '-','::1','127.0.0.1' })
    foreach ($g in ($ext | Group-Object IP)) { if ($g.Count -ge 3) { $lines.Add(("🟠 ログイン失敗が続いています: 接続元={0} {1}回（ユーザー: {2}）" -f $g.Name, $g.Count, (($g.Group | Select-Object -ExpandProperty User -Unique) -join ','))) } }
    $loc = @($f | Where-Object { -not $_.IP -or $_.IP -in '-','::1','127.0.0.1' })
    if ($loc.Count -ge 5) { $lines.Add(("🟡 この PC の中でのログイン失敗が {0} 回ありました" -f $loc.Count)) }
} catch {}

# 3) 新しいユーザー・管理者グループへの追加・ユーザーの有効化
foreach ($q in @(@{I=4720;T='🔴 新しいユーザーが作られました'},@{I=4732;T='🔴 グループにメンバーが追加されました'},@{I=4722;T='🟠 ユーザーが有効化されました'},@{I=4724;T='🟠 パスワードのリセットが行われました'})) {
    try { Get-WinEvent -FilterHashtable @{LogName='Security'; Id=$q.I; StartTime=$since} -ErrorAction Stop | ForEach-Object { $d = Get-Data $_; $lines.Add(("{0}: {1:MM/dd HH:mm:ss} 対象={2} 実行者={3}" -f $q.T, $_.TimeCreated, $d.TargetUserName, $d.SubjectUserName)) } } catch {}
}

# 4) 新しいサービス
try { Get-WinEvent -FilterHashtable @{LogName='System'; Id=7045; StartTime=$since} -ErrorAction Stop | ForEach-Object { $d = Get-Data $_; $lines.Add(("🟠 新しいサービス: {0:MM/dd HH:mm:ss} {1} | {2}" -f $_.TimeCreated, $d.ServiceName, $d.ImagePath)) } } catch {}

if ($lines.Count -gt 0) {
    $shown = @($lines | Select-Object -First 12)
    $more = if ($lines.Count -gt 12) { "`n…ほか {0} 件" -f ($lines.Count - 12) } else { '' }
    Send-Alert ("⚠️ SecurityWatchLogon（$env:COMPUTERNAME）`n" + ($shown -join "`n") + $more)
} elseif ($DryRun) { Write-Output "異常なし（前回以降）" }

if (-not $DryRun) { Set-Content -Path $lastF -Value $now.ToString('o') }

}

function Invoke-Install {
    param([string]$InstallDir, [switch]$NoSystemChanges, [switch]$NoTasks, [switch]$Test)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName Microsoft.VisualBasic

function Msg([string]$text, [string]$buttons = 'OK') {
    $b = if ($buttons -eq 'YesNo') { [Windows.Forms.MessageBoxButtons]::YesNo } else { [Windows.Forms.MessageBoxButtons]::OK }
    return [Windows.Forms.MessageBox]::Show($text, 'SecurityWatch インストーラ', $b, [Windows.Forms.MessageBoxIcon]::Information)
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin -and -not $Test) { Msg "管理者権限で実行してください。SecurityWatch.cmd をダブルクリックしてください。" | Out-Null; exit 1 }

$here = $PSScriptRoot
$self = $PSCommandPath
$user = $env:USERNAME

$explain = @"
SecurityWatch を、この PC に入れます。内容は次のとおりです。

【入れるもの】
・見守りのプログラム（保存先: $InstallDir）
・5分おきに動く予約タスク 2つ（PCの変化を見るもの / ログインの記録を見るもの）

【Windows の設定を変更します】（OFFにしたい場合は、キャンセルして、README をお読みください）
・セキュリティの記録（ログ）の大きさを 256MB にする（約2週間分、残ります）
・ログインの成功・失敗、アカウントの作成などを、記録する設定を ON にする

【通知】
・あなた自身の Discord だけに送ります。作者には、何も送られません。
・通知に、パスワードやキーは入りません。

【これは、セキュリティソフトの代わりではありません】
入られるのを防ぐものではなく、変化に気づくための道具です。

インストールしますか？
"@
if ($Test) { Write-Output $explain } elseif ((Msg $explain 'YesNo') -ne 'Yes') { exit 0 }

# 1) フォルダとファイル
New-Item -ItemType Directory -Force $InstallDir | Out-Null
Copy-Item $self (Join-Path $InstallDir 'SecurityWatch.ps1') -Force
$vbs = 'CreateObject("WScript.Shell").Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""' + (Join-Path $InstallDir 'SecurityWatch.ps1') + '"" -Mode Watch", 0, False'
[IO.File]::WriteAllText((Join-Path $InstallDir 'run.vbs'), $vbs, [Text.Encoding]::ASCII)
if (-not $Test) {
    # 保存先を、管理者・SYSTEM・このユーザーだけが使える形にする
    & icacls $InstallDir /inheritance:r /grant:r "SYSTEM:(OI)(CI)F" "Administrators:(OI)(CI)F" "${user}:(OI)(CI)M" | Out-Null
}

# 2) Discord の Webhook
$hookF = Join-Path $InstallDir 'webhook.txt'
$url = ''
if (-not $Test) {
    $url = ([Microsoft.VisualBasic.Interaction]::InputBox("Discord で作った Webhook の URL を貼り付けて「OK」を押してください。`r`n（通知を受けるチャンネルの「連携」→「ウェブフック」→「新しいウェブフック」→「ウェブフックURLをコピー」）`r`n`r`n空のまま「OK」を押すと、通知なしで、記録だけを残します（あとから設定できます）。", 'SecurityWatch - Discord設定', '') + '').Trim()
}
if ($url -ne '') {
    if ($url -match '^https://(discord|discordapp)\.com/api/webhooks/\d+/[\w\-]+$') {
        Set-Content -Path $hookF -Value $url -Encoding ASCII
    } else { Msg "URL の形が違うようです。Discord の設定は、スキップします（あとから、webhook.txt に URL を保存できます）。" | Out-Null }
}

# 3) Windows の設定（ログの大きさと、記録する項目）
if (-not $NoSystemChanges -and -not $Test) {
    & wevtutil sl Security /ms:268435456
    $subs = '{0CCE9215-69AE-11D9-BED3-505054503030}', '{0CCE9216-69AE-11D9-BED3-505054503030}', '{0CCE9217-69AE-11D9-BED3-505054503030}',
            '{0CCE9235-69AE-11D9-BED3-505054503030}', '{0CCE9237-69AE-11D9-BED3-505054503030}', '{0CCE9227-69AE-11D9-BED3-505054503030}'
    foreach ($g in $subs) { & auditpol /set /subcategory:"$g" /success:enable /failure:enable | Out-Null }
}

# 4) 予約タスク
if (-not $NoTasks -and -not $Test) {
    $set = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 3) -MultipleInstances IgnoreNew
    $trg = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 5) -RepetitionDuration (New-TimeSpan -Days 3650)
    # (a) PCの変化を見る：インストールしたユーザーとして（そのユーザーが見える範囲を、毎回同じ条件で見るため）
    $act1 = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument ('//B "' + (Join-Path $InstallDir 'run.vbs') + '"')
    $pri1 = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$user" -LogonType Interactive -RunLevel Limited
    Register-ScheduledTask -TaskName 'SecurityWatch' -Action $act1 -Trigger $trg -Settings $set -Principal $pri1 -Description 'PCの変化を5分おきに確認（SecurityWatch）' -Force | Out-Null
    # (b) ログインの記録を見る：SYSTEM（セキュリティの記録を読むため）
    $act2 = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + (Join-Path $InstallDir 'SecurityWatch.ps1') + '" -Mode Logon')
    $pri2 = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    Register-ScheduledTask -TaskName 'SecurityWatchLogon' -Action $act2 -Trigger $trg -Settings $set -Principal $pri2 -Description 'ログイン・失敗・新ユーザーを5分おきに確認（SecurityWatch）' -Force | Out-Null
}

if ($Test) { Write-Output "[Test] 確認のみ。インストール先: $InstallDir"; exit 0 }
Msg "インストールが終わりました。`r`n`r`n・1〜2分後に、最初の確認が動きます。Discord を設定した場合は、「開始しました」という通知が届きます。`r`n・毎日1回、「動いています」という通知が届きます（届かなくなったら、止まっています）。`r`n・やめたいときは、もう一度 SecurityWatch.cmd をダブルクリックして、「いいえ（削除）」を選んでください。" | Out-Null

}

function Invoke-Uninstall {
    param([string]$InstallDir)
Add-Type -AssemblyName System.Windows.Forms
$ans = [Windows.Forms.MessageBox]::Show("SecurityWatch を削除します。`r`n・予約タスク2つを削除`r`n・見守りのフォルダ（記録・設定・Webhook）を削除`r`n`r`n※Windows の「ログの大きさ」「記録する設定」は、元に戻しません（そのままでも、問題ありません）。`r`n`r`nよろしいですか？", 'SecurityWatch アンインストーラ', [Windows.Forms.MessageBoxButtons]::YesNo, [Windows.Forms.MessageBoxIcon]::Question)
if ($ans -ne 'Yes') { exit 0 }
foreach ($t in 'SecurityWatch', 'SecurityWatchLogon') { try { Unregister-ScheduledTask -TaskName $t -Confirm:$false -ErrorAction Stop } catch {} }
Start-Sleep 1
if (Test-Path $InstallDir) { Remove-Item $InstallDir -Recurse -Force -ErrorAction SilentlyContinue }
[Windows.Forms.MessageBox]::Show("削除しました。", 'SecurityWatch アンインストーラ') | Out-Null

}

switch ($Mode) {
    'Watch'     { Invoke-Watch -DryRun:$DryRun -Heartbeat:$Heartbeat }
    'Logon'     { Invoke-Logon -DryRun:$DryRun }
    'Install'   { Invoke-Install -InstallDir $InstallDir -NoSystemChanges:$NoSystemChanges -NoTasks:$NoTasks -Test:$Test }
    'Uninstall' { Invoke-Uninstall -InstallDir $InstallDir }
    'Menu' {
        Add-Type -AssemblyName System.Windows.Forms
        $r = [Windows.Forms.MessageBox]::Show("SecurityWatch です。`r`n`r`n「はい」　　　：インストールする`r`n「いいえ」　　：削除する`r`n「キャンセル」：何もしない", 'SecurityWatch', [Windows.Forms.MessageBoxButtons]::YesNoCancel, [Windows.Forms.MessageBoxIcon]::Question)
        if ($r -eq 'Yes') { Invoke-Install -InstallDir $InstallDir -NoSystemChanges:$NoSystemChanges -NoTasks:$NoTasks -Test:$Test }
        elseif ($r -eq 'No') { Invoke-Uninstall -InstallDir $InstallDir }
    }
}
