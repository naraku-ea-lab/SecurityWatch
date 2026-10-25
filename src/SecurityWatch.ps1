# SecurityWatch.ps1  -  PC の「勝手な変更」「外からの接続」に気づくための、軽い監視（管理者権限は不要）
#  ・前回との差（増えたもの）だけを通知する。最初の実行は、基準（ベースライン）を保存するだけ。
#  ・通知先: インストール先の webhook.txt に Discord Webhook URL（1行）があれば Discord へ。無ければ alerts.log に記録のみ。
#  ・通知に、パスワードやキーは含めない（項目名・時刻・接続元IPなどだけ）。
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
