# SecurityWatchLogon.ps1  -  外からのログイン・ログイン失敗・新しいユーザー等を、Windowsのセキュリティ記録から読んで、Discordに知らせる
#  ・管理者権限（SYSTEM）のタスクで、5分おきに動く。前回の確認以降の分だけを見る。
#  ・通知に、パスワードやキーは含めない（時刻・ユーザー名・接続元IP・種類だけ）。
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
