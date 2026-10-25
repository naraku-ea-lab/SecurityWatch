# SecurityWatch アンインストーラ（管理者権限で実行されます）
param([string]$InstallDir = (Join-Path $env:ProgramData 'SecurityWatch'))
Add-Type -AssemblyName System.Windows.Forms
$ans = [Windows.Forms.MessageBox]::Show("SecurityWatch を削除します。`r`n・予約タスク2つを削除`r`n・見守りのフォルダ（記録・設定・Webhook）を削除`r`n`r`n※Windows の「ログの大きさ」「記録する設定」は、元に戻しません（そのままでも、問題ありません）。`r`n`r`nよろしいですか？", 'SecurityWatch アンインストーラ', [Windows.Forms.MessageBoxButtons]::YesNo, [Windows.Forms.MessageBoxIcon]::Question)
if ($ans -ne 'Yes') { exit 0 }
foreach ($t in 'SecurityWatch', 'SecurityWatchLogon') { try { Unregister-ScheduledTask -TaskName $t -Confirm:$false -ErrorAction Stop } catch {} }
Start-Sleep 1
if (Test-Path $InstallDir) { Remove-Item $InstallDir -Recurse -Force -ErrorAction SilentlyContinue }
[Windows.Forms.MessageBox]::Show("削除しました。", 'SecurityWatch アンインストーラ') | Out-Null
