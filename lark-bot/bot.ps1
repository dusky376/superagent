# 飞书 @ 应答机器人 —— 启动 / 停止 / 状态 / 日志
# 用法：.\bot.ps1 start | stop | restart | status | log
param(
    [Parameter(Position = 0)]
    [ValidateSet('start', 'stop', 'restart', 'status', 'log')]
    [string]$Action = 'start',
    [int]$Tail = 30
)

$ErrorActionPreference = 'Stop'
$Root    = Split-Path -Parent $MyInvocation.MyCommand.Path
$Script  = Join-Path $Root 'lark-bot.mjs'
$PidFile = Join-Path $Root 'data\bot.pid'
$LogFile = Join-Path $Root 'data\bot.log'
$OutLog  = Join-Path $Root 'data\stdout.log'
$ErrLog  = Join-Path $Root 'data\stderr.log'

New-Item -ItemType Directory -Force -Path (Join-Path $Root 'data') | Out-Null

function Get-BotProcess {
    if (-not (Test-Path $PidFile)) { return $null }
    $id = (Get-Content $PidFile -ErrorAction SilentlyContinue | Select-Object -First 1)
    if (-not $id) { return $null }
    $p = Get-Process -Id $id -ErrorAction SilentlyContinue
    if ($p -and $p.ProcessName -eq 'node') { return $p }
    Remove-Item $PidFile -Force -ErrorAction SilentlyContinue
    return $null
}

switch ($Action) {
    'start' {
        $running = Get-BotProcess
        if ($running) { Write-Host "已在运行 (PID $($running.Id))"; exit 0 }

        $p = Start-Process -FilePath 'node' -ArgumentList @($Script) -WorkingDirectory $Root `
             -WindowStyle Hidden -PassThru `
             -RedirectStandardOutput $OutLog -RedirectStandardError $ErrLog
        $p.Id | Set-Content -Path $PidFile -Encoding ascii
        Start-Sleep -Seconds 3

        if (-not (Get-Process -Id $p.Id -ErrorAction SilentlyContinue)) {
            Write-Host "启动失败，查看 $ErrLog ：" -ForegroundColor Red
            Get-Content $ErrLog -Tail 20 -ErrorAction SilentlyContinue
            exit 1
        }
        Write-Host "已启动 (PID $($p.Id))" -ForegroundColor Green
        Write-Host "日志：$LogFile"
    }
    'stop' {
        $running = Get-BotProcess
        if (-not $running) { Write-Host '未在运行'; exit 0 }
        Stop-Process -Id $running.Id -Force
        Remove-Item $PidFile -Force -ErrorAction SilentlyContinue
        Write-Host "已停止 (PID $($running.Id))" -ForegroundColor Yellow
    }
    'restart' {
        & $MyInvocation.MyCommand.Path stop
        Start-Sleep -Seconds 1
        & $MyInvocation.MyCommand.Path start
    }
    'status' {
        $running = Get-BotProcess
        if ($running) {
            Write-Host "运行中 (PID $($running.Id))" -ForegroundColor Green
            Write-Host "启动时间：$($running.StartTime)"
        } else {
            Write-Host '未运行' -ForegroundColor Yellow
        }
        if (Test-Path $LogFile) {
            Write-Host "`n--- 最近日志 ---"
            Get-Content $LogFile -Tail $Tail -Encoding UTF8
        }
    }
    'log' {
        if (-not (Test-Path $LogFile)) { Write-Host "暂无日志 $LogFile"; exit 0 }
        Get-Content $LogFile -Tail $Tail -Encoding UTF8 -Wait
    }
}
