# bootstrap.ps1
# Run once on the Windows EC2 instance (manually or via SSM Run Command).
# 1. Installs the CloudWatch Agent
# 2. Drops cwa-config.json into the agent config dir
# 3. Starts the agent
# 4. Registers service-metrics.ps1 as a Task Scheduler job (every 1 min)

$ErrorActionPreference = "Stop"

# ── Config ────────────────────────────────────────────────────────────────────
$CWA_INSTALLER = "https://s3.amazonaws.com/amazoncloudwatch-agent/windows/amd64/latest/amazon-cloudwatch-agent.msi"
$CWA_CONFIG_DIR = "C:\ProgramData\Amazon\AmazonCloudWatchAgent"
$SCRIPTS_DIR    = "C:\app\scripts"
$LOG_DIR        = "C:\app\logs"

# ── 1. Download & install CloudWatch Agent ────────────────────────────────────
Write-Output "Installing CloudWatch Agent..."
$installer = "$env:TEMP\amazon-cloudwatch-agent.msi"
Invoke-WebRequest -Uri $CWA_INSTALLER -OutFile $installer -UseBasicParsing
Start-Process msiexec.exe -ArgumentList "/i `"$installer`" /quiet /norestart" -Wait
Remove-Item $installer -Force
Write-Output "CloudWatch Agent installed."

# ── 2. Place agent config ─────────────────────────────────────────────────────
Write-Output "Writing CWA config..."
New-Item -ItemType Directory -Force -Path $CWA_CONFIG_DIR | Out-Null

# Config is embedded here; in a real pipeline you'd pull it from S3 or Parameter Store.
$config = @'
{
  "metrics": {
    "namespace": "CSG/System",
    "metrics_collected": {
      "Memory": {
        "measurement": ["% Committed Bytes In Use"],
        "metrics_collection_interval": 60
      },
      "LogicalDisk": {
        "measurement": ["% Free Space", "Disk Read Bytes/sec", "Disk Write Bytes/sec"],
        "metrics_collection_interval": 60,
        "resources": ["C:", "D:"]
      }
    },
    "append_dimensions": {
      "InstanceId": "${aws:InstanceId}",
      "InstanceType": "${aws:InstanceType}"
    }
  },
  "logs": {
    "logs_collected": {
      "windows_events": {
        "collect_list": [{
          "event_name": "System",
          "event_levels": ["WARNING","ERROR","CRITICAL"],
          "log_group_name": "/windows/system",
          "log_stream_name": "{instance_id}"
        }]
      },
      "files": {
        "collect_list": [{
          "file_path": "C:\\app\\logs\\api.log",
          "log_group_name": "/app/api",
          "log_stream_name": "{instance_id}",
          "timestamp_format": "%Y-%m-%dT%H:%M:%S"
        }]
      }
    }
  }
}
'@

Set-Content -Path "$CWA_CONFIG_DIR\amazon-cloudwatch-agent.json" -Value $config -Encoding UTF8

# ── 3. Start CloudWatch Agent ─────────────────────────────────────────────────
Write-Output "Starting CloudWatch Agent..."
& "C:\Program Files\Amazon\AmazonCloudWatchAgent\amazon-cloudwatch-agent-ctl.ps1" `
    -a fetch-config `
    -m ec2 `
    -s `
    -c "file:$CWA_CONFIG_DIR\amazon-cloudwatch-agent.json"
Write-Output "CloudWatch Agent started."

# ── 4. Place service-metrics script ──────────────────────────────────────────
Write-Output "Setting up service-metrics script..."
New-Item -ItemType Directory -Force -Path $SCRIPTS_DIR | Out-Null
New-Item -ItemType Directory -Force -Path $LOG_DIR     | Out-Null

# Copy script from same directory as bootstrap (adjust if pulling from S3)
$scriptSrc = Join-Path $PSScriptRoot "service-metrics.ps1"
Copy-Item -Path $scriptSrc -Destination "$SCRIPTS_DIR\service-metrics.ps1" -Force

# ── 5. Register Task Scheduler job ────────────────────────────────────────────
Write-Output "Registering Task Scheduler task..."
$action  = New-ScheduledTaskAction `
              -Execute "powershell.exe" `
              -Argument "-NonInteractive -ExecutionPolicy Bypass -File `"$SCRIPTS_DIR\service-metrics.ps1`""
$trigger = New-ScheduledTaskTrigger -RepetitionInterval (New-TimeSpan -Minutes 1) -Once -At (Get-Date)
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 1) -MultipleInstances IgnoreNew
$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -RunLevel Highest

Register-ScheduledTask `
    -TaskName   "CWA-ServiceMetrics" `
    -Action     $action `
    -Trigger    $trigger `
    -Settings   $settings `
    -Principal  $principal `
    -Force | Out-Null

Write-Output "Task 'CWA-ServiceMetrics' registered (runs every 1 min as SYSTEM)."
Write-Output "Bootstrap complete."
