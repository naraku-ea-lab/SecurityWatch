# SecurityWatch インストーラ（管理者権限で実行されます）
param([string]$InstallDir = (Join-Path $env:ProgramData 'SecurityWatch'), [switch]$NoSystemChanges, [switch]$NoTasks, [switch]$Test)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName Microsoft.VisualBasic

function Msg([string]$text, [string]$buttons = 'OK') {
    $b = if ($buttons -eq 'YesNo') { [Windows.Forms.MessageBoxButtons]::YesNo } else { [Windows.Forms.MessageBoxButtons]::OK }
    return [Windows.Forms.MessageBox]::Show($text, 'SecurityWatch インストーラ', $b, [Windows.Forms.MessageBoxIcon]::Information)
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin -and -not $Test) { Msg "管理者権限で実行してください。Install.cmd をダブルクリックしてください。" | Out-Null; exit 1 }

$here = $PSScriptRoot
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
foreach ($f in 'SecurityWatch.ps1', 'SecurityWatchLogon.ps1') { Copy-Item (Join-Path $here $f) (Join-Path $InstallDir $f) -Force }
$vbs = 'CreateObject("WScript.Shell").Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""' + (Join-Path $InstallDir 'SecurityWatch.ps1') + '""", 0, False'
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
    $act2 = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + (Join-Path $InstallDir 'SecurityWatchLogon.ps1') + '"')
    $pri2 = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    Register-ScheduledTask -TaskName 'SecurityWatchLogon' -Action $act2 -Trigger $trg -Settings $set -Principal $pri2 -Description 'ログイン・失敗・新ユーザーを5分おきに確認（SecurityWatch）' -Force | Out-Null
}

if ($Test) { Write-Output "[Test] 確認のみ。インストール先: $InstallDir"; exit 0 }
Msg "インストールが終わりました。`r`n`r`n・1〜2分後に、最初の確認が動きます。Discord を設定した場合は、「開始しました」という通知が届きます。`r`n・毎日1回、「動いています」という通知が届きます（届かなくなったら、止まっています）。`r`n・やめたいときは、Uninstall.cmd をダブルクリックしてください。" | Out-Null
