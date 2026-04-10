# bootstrap.ps1
# Run manually on the instance via SSM Session Manager if user_data didn't complete.
# Mirrors the user_data block in terraform/main.tf exactly.

$ErrorActionPreference = "Stop"
$logFile = "C:\bootstrap.log"
function Log { param($msg) $ts = Get-Date -Format "u"; "$ts $msg" | Tee-Object -FilePath $logFile -Append }

Log "=== Bootstrap started ==="

# ── 1. Install CloudWatch Agent ───────────────────────────────────────────────
Log "Downloading CWA..."
$msi = "$env:TEMP\cwa.msi"
Invoke-WebRequest -Uri "https://s3.amazonaws.com/amazoncloudwatch-agent/windows/amd64/latest/amazon-cloudwatch-agent.msi" -OutFile $msi -UseBasicParsing
Start-Process msiexec.exe -ArgumentList "/i `"$msi`" /quiet /norestart" -Wait
Remove-Item $msi -Force
Log "CWA installed."

# ── 2. Write CWA config (no BOM) ─────────────────────────────────────────────
$cfgDir = "C:\ProgramData\Amazon\AmazonCloudWatchAgent"
New-Item -ItemType Directory -Force -Path $cfgDir | Out-Null

$cwaConfig = '{"metrics":{"namespace":"CSG/System","metrics_collected":{"Memory":{"measurement":["% Committed Bytes In Use"],"metrics_collection_interval":60},"LogicalDisk":{"measurement":["% Free Space"],"metrics_collection_interval":60,"resources":["C:"]}},"append_dimensions":{"InstanceId":"${aws:InstanceId}"}}}'
[System.IO.File]::WriteAllText("$cfgDir\amazon-cloudwatch-agent.json", $cwaConfig, (New-Object System.Text.UTF8Encoding $false))
Log "CWA config written (no BOM)."

# ── 3. Start CWA ─────────────────────────────────────────────────────────────
& "C:\Program Files\Amazon\AmazonCloudWatchAgent\amazon-cloudwatch-agent-ctl.ps1" -a fetch-config -m ec2 -s -c "file:$cfgDir\amazon-cloudwatch-agent.json"
Log "CWA started."

# ── 4. Write service-metrics script and register Task Scheduler job ──────────
$scriptsDir = "C:\app\scripts"
$logsDir    = "C:\app\logs"
$apiDir     = "C:\app\api"
New-Item -ItemType Directory -Force -Path $scriptsDir | Out-Null
New-Item -ItemType Directory -Force -Path $logsDir    | Out-Null
New-Item -ItemType Directory -Force -Path $apiDir     | Out-Null

$svcScript = @'
param([string]$Region="us-west-2",[string]$Namespace="CSG/Services",[string]$ServiceName="SMTPSVC")
try { $svc = Get-Service $ServiceName -EA Stop; $v = if ($svc.Status -eq "Running") { 1 } else { 0 } } catch { $v = 0 }
try {
    $tok = Invoke-RestMethod -Method PUT "http://169.254.169.254/latest/api/token" -Headers @{"X-aws-ec2-metadata-token-ttl-seconds"="21600"} -TimeoutSec 2
    $id  = Invoke-RestMethod "http://169.254.169.254/latest/meta-data/instance-id" -Headers @{"X-aws-ec2-metadata-token"=$tok} -TimeoutSec 2
} catch { $id = "unknown" }
aws cloudwatch put-metric-data --region $Region --namespace $Namespace --metric-data "[{`"MetricName`":`"ServiceRunning`",`"Dimensions`":[{`"Name`":`"InstanceId`",`"Value`":`"$id`"}],`"Value`":$v,`"Unit`":`"Count`"}]"
'@
[System.IO.File]::WriteAllText("$scriptsDir\service-metrics.ps1", $svcScript, (New-Object System.Text.UTF8Encoding $false))

$action    = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NonInteractive -ExecutionPolicy Bypass -File `"$scriptsDir\service-metrics.ps1`""
$trigger   = New-ScheduledTaskTrigger -RepetitionInterval (New-TimeSpan -Minutes 1) -Once -At (Get-Date)
$settings  = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 1) -MultipleInstances IgnoreNew
$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -RunLevel Highest
Register-ScheduledTask -TaskName "CWA-ServiceMetrics" -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null
Log "Service-metrics task registered."

# ── 5. Install Python 3.12 ────────────────────────────────────────────────────
Log "Downloading Python 3.12..."
$pyInstaller = "$env:TEMP\python312.exe"
Invoke-WebRequest -Uri "https://www.python.org/ftp/python/3.12.3/python-3.12.3-amd64.exe" -OutFile $pyInstaller -UseBasicParsing
Log "Installing Python 3.12 (this takes ~1 min)..."
Start-Process $pyInstaller -ArgumentList "/quiet InstallAllUsers=1 PrependPath=1 Include_pip=1" -Wait
Remove-Item $pyInstaller -Force
$env:PATH = [System.Environment]::GetEnvironmentVariable("PATH", "Machine")
Log "Python installed."

# ── 6. Pull app files from GitHub ────────────────────────────────────────────
Log "Downloading FastAPI app..."
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/arizvi002/aws-observability-demo/main/app/main.py" -OutFile "$apiDir\main.py" -UseBasicParsing
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/arizvi002/aws-observability-demo/main/app/requirements.txt" -OutFile "$apiDir\requirements.txt" -UseBasicParsing
Log "App files downloaded."

# ── 7. pip install ────────────────────────────────────────────────────────────
Log "Installing Python dependencies..."
& "C:\Program Files\Python312\python.exe" -m pip install --quiet -r "$apiDir\requirements.txt"
Log "Dependencies installed."

# ── 8. Write start-api.ps1 ───────────────────────────────────────────────────
$startApi = @'
Set-Location "C:\app\api"
& "C:\Program Files\Python312\Scripts\uvicorn.exe" main:app --host 0.0.0.0 --port 8000 --log-level info *>> "C:\app\logs\api.log"
'@
[System.IO.File]::WriteAllText("$scriptsDir\start-api.ps1", $startApi, (New-Object System.Text.UTF8Encoding $false))

# ── 9. Register FastAPI as a startup Task Scheduler job ──────────────────────
$apiAction    = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NonInteractive -ExecutionPolicy Bypass -File `"$scriptsDir\start-api.ps1`""
$apiTrigger   = New-ScheduledTaskTrigger -AtStartup
$apiSettings  = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -MultipleInstances IgnoreNew
$apiPrincipal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -RunLevel Highest
Register-ScheduledTask -TaskName "FastAPI-Server" -Action $apiAction -Trigger $apiTrigger -Settings $apiSettings -Principal $apiPrincipal -Force | Out-Null
Log "FastAPI task registered."

# ── 10. Start FastAPI now ─────────────────────────────────────────────────────
Start-ScheduledTask -TaskName "FastAPI-Server"
Log "FastAPI task started."

Log "=== Bootstrap complete ==="
