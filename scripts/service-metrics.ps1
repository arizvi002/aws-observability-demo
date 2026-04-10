# service-metrics.ps1
# Publishes SMTPSVC running state to CloudWatch as CSG/Services / ServiceRunning
# Value: 1 = running, 0 = stopped/missing
# Run every 1 minute via Task Scheduler (see bootstrap.ps1).

param(
    [string]$Region      = "us-west-2",
    [string]$Namespace   = "CSG/Services",
    [string]$ServiceName = "SMTPSVC"
)

$ErrorActionPreference = "Stop"

# 1. Check service state
try {
    $svc   = Get-Service -Name $ServiceName -ErrorAction Stop
    $value = if ($svc.Status -eq "Running") { 1 } else { 0 }
} catch {
    Write-Warning "Service '$ServiceName' not found: $_"
    $value = 0
}

# 2. Fetch instance ID via IMDSv2
try {
    $token  = Invoke-RestMethod -Method PUT `
                -Uri "http://169.254.169.254/latest/api/token" `
                -Headers @{"X-aws-ec2-metadata-token-ttl-seconds" = "21600"} `
                -TimeoutSec 2
    $instId = Invoke-RestMethod `
                -Uri "http://169.254.169.254/latest/meta-data/instance-id" `
                -Headers @{"X-aws-ec2-metadata-token" = $token} `
                -TimeoutSec 2
} catch {
    $instId = "unknown"
}

# 3. Build and send PutMetricData via AWS CLI (avoids SDK dependency in plain PS)
$metricJson = @"
[{
  "MetricName": "ServiceRunning",
  "Dimensions": [{"Name":"InstanceId","Value":"$instId"},{"Name":"ServiceName","Value":"$ServiceName"}],
  "Value": $value,
  "Unit": "Count"
}]
"@

aws cloudwatch put-metric-data `
    --region     $Region `
    --namespace  $Namespace `
    --metric-data $metricJson

Write-Output "$(Get-Date -Format 'u') | $ServiceName=$value published to $Namespace/ServiceRunning (instance=$instId)"
