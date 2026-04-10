terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.region
}

# ── AMI: latest Windows Server 2022 Full ─────────────────────────────────────
data "aws_ami" "windows" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["Windows_Server-2022-English-Full-Base-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# ── IAM: role + instance profile ─────────────────────────────────────────────
data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ec2" {
  name               = "${var.project}-ec2-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_role_policy_attachment" "cwa" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ec2" {
  name = "${var.project}-instance-profile"
  role = aws_iam_role.ec2.name
}

# ── Security group: FastAPI on 8000 ──────────────────────────────────────────
resource "aws_security_group" "ec2" {
  name        = "${var.project}-sg"
  description = "Allow FastAPI traffic and outbound"

  ingress {
    description = "FastAPI"
    from_port   = 8000
    to_port     = 8000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name    = "${var.project}-sg"
    Project = var.project
  }
}

# ── EC2: Windows Server t3.micro ─────────────────────────────────────────────
resource "aws_instance" "windows" {
  ami                    = data.aws_ami.windows.id
  instance_type          = var.instance_type
  iam_instance_profile   = aws_iam_instance_profile.ec2.name
  vpc_security_group_ids = [aws_security_group.ec2.id]

  user_data_replace_on_change = true

  user_data = <<-USERDATA
    <powershell>
    $ErrorActionPreference = "Stop"
    $logFile = "C:\bootstrap.log"
    function Log { param($msg) $ts = Get-Date -Format "u"; "$ts $msg" | Tee-Object -FilePath $logFile -Append }

    Log "=== Bootstrap started ==="

    # ── 1. Install CloudWatch Agent ───────────────────────────────────────────
    Log "Downloading CWA..."
    $msi = "$env:TEMP\cwa.msi"
    Invoke-WebRequest -Uri "https://s3.amazonaws.com/amazoncloudwatch-agent/windows/amd64/latest/amazon-cloudwatch-agent.msi" -OutFile $msi -UseBasicParsing
    Start-Process msiexec.exe -ArgumentList "/i `"$msi`" /quiet /norestart" -Wait
    Remove-Item $msi -Force
    Log "CWA installed."

    # ── 2. Write CWA config (no BOM) ─────────────────────────────────────────
    $cfgDir = "C:\ProgramData\Amazon\AmazonCloudWatchAgent"
    New-Item -ItemType Directory -Force -Path $cfgDir | Out-Null

    $cwaConfig = '{"metrics":{"namespace":"CSG/System","metrics_collected":{"Memory":{"measurement":["% Committed Bytes In Use"],"metrics_collection_interval":60},"LogicalDisk":{"measurement":["% Free Space"],"metrics_collection_interval":60,"resources":["C:"]}},"append_dimensions":{"InstanceId":"${aws:InstanceId}"}}}'
    [System.IO.File]::WriteAllText("$cfgDir\amazon-cloudwatch-agent.json", $cwaConfig, (New-Object System.Text.UTF8Encoding $false))
    Log "CWA config written."

    # ── 3. Start CWA ─────────────────────────────────────────────────────────
    & "C:\Program Files\Amazon\AmazonCloudWatchAgent\amazon-cloudwatch-agent-ctl.ps1" -a fetch-config -m ec2 -s -c "file:$cfgDir\amazon-cloudwatch-agent.json"
    Log "CWA started."

    # ── 4. Write service-metrics script ──────────────────────────────────────
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

    $action   = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NonInteractive -ExecutionPolicy Bypass -File `"$scriptsDir\service-metrics.ps1`""
    $trigger  = New-ScheduledTaskTrigger -RepetitionInterval (New-TimeSpan -Minutes 1) -Once -At (Get-Date)
    $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 1) -MultipleInstances IgnoreNew
    $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -RunLevel Highest
    Register-ScheduledTask -TaskName "CWA-ServiceMetrics" -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null
    Log "Service-metrics task registered."

    # ── 5. Install Python 3.12 ────────────────────────────────────────────────
    Log "Downloading Python 3.12..."
    $pyInstaller = "$env:TEMP\python312.exe"
    Invoke-WebRequest -Uri "https://www.python.org/ftp/python/3.12.3/python-3.12.3-amd64.exe" -OutFile $pyInstaller -UseBasicParsing
    Log "Installing Python 3.12..."
    Start-Process $pyInstaller -ArgumentList "/quiet InstallAllUsers=1 PrependPath=1 Include_pip=1" -Wait
    Remove-Item $pyInstaller -Force
    $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH", "Machine")
    Log "Python installed."

    # ── 6. Pull app files from GitHub ────────────────────────────────────────
    Log "Downloading FastAPI app..."
    Invoke-WebRequest -Uri "https://raw.githubusercontent.com/arizvi002/aws-observability-demo/main/app/main.py" -OutFile "$apiDir\main.py" -UseBasicParsing
    Invoke-WebRequest -Uri "https://raw.githubusercontent.com/arizvi002/aws-observability-demo/main/app/requirements.txt" -OutFile "$apiDir\requirements.txt" -UseBasicParsing
    Log "App files downloaded."

    # ── 7. pip install ────────────────────────────────────────────────────────
    Log "Installing Python dependencies..."
    & "C:\Program Files\Python312\python.exe" -m pip install --quiet -r "$apiDir\requirements.txt"
    Log "Dependencies installed."

    # ── 8. Write start-api.ps1 ───────────────────────────────────────────────
    $startApi = @'
Set-Location "C:\app\api"
& "C:\Program Files\Python312\Scripts\uvicorn.exe" main:app --host 0.0.0.0 --port 8000 --log-level info *>> "C:\app\logs\api.log"
'@
    [System.IO.File]::WriteAllText("$scriptsDir\start-api.ps1", $startApi, (New-Object System.Text.UTF8Encoding $false))

    # ── 9. Register FastAPI as a startup Task Scheduler job ──────────────────
    $apiAction    = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NonInteractive -ExecutionPolicy Bypass -File `"$scriptsDir\start-api.ps1`""
    $apiTrigger   = New-ScheduledTaskTrigger -AtStartup
    $apiSettings  = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -MultipleInstances IgnoreNew
    $apiPrincipal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -RunLevel Highest
    Register-ScheduledTask -TaskName "FastAPI-Server" -Action $apiAction -Trigger $apiTrigger -Settings $apiSettings -Principal $apiPrincipal -Force | Out-Null
    Log "FastAPI task registered."

    # ── 10. Start FastAPI now ─────────────────────────────────────────────────
    Start-ScheduledTask -TaskName "FastAPI-Server"
    Log "FastAPI task started."

    Log "=== Bootstrap complete ==="
    </powershell>
  USERDATA

  tags = {
    Name    = "${var.project}-windows"
    Project = var.project
  }
}

# ── SNS topic + email subscription ───────────────────────────────────────────
resource "aws_sns_topic" "alarms" {
  name = "${var.project}-alarms"
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alarms.arn
  protocol  = "email"
  endpoint  = var.sns_email
}

# ── CloudWatch Alarm: SMTPSVC down ───────────────────────────────────────────
resource "aws_cloudwatch_metric_alarm" "smtpsvc_down" {
  alarm_name          = "${var.project}-smtpsvc-down"
  alarm_description   = "SMTPSVC is not running on ${aws_instance.windows.id}"
  namespace           = "CSG/Services"
  metric_name         = "ServiceRunning"
  dimensions          = { InstanceId = aws_instance.windows.id }
  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = 2
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching"
  alarm_actions       = [aws_sns_topic.alarms.arn]
  ok_actions          = [aws_sns_topic.alarms.arn]
}

# ── CloudWatch Dashboard ──────────────────────────────────────────────────────
resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = "${var.project}-dashboard"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6
        properties = {
          title  = "CPU Utilization"
          region = var.region
          metrics = [[
            "AWS/EC2", "CPUUtilization",
            "InstanceId", aws_instance.windows.id,
            { stat = "Average", period = 60 }
          ]]
          view   = "timeSeries"
          period = 60
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 0
        width  = 12
        height = 6
        properties = {
          title  = "SMTPSVC ServiceRunning"
          region = var.region
          metrics = [[
            "CSG/Services", "ServiceRunning",
            "InstanceId", aws_instance.windows.id,
            { stat = "Minimum", period = 60, color = "#d62728" }
          ]]
          view   = "timeSeries"
          period = 60
          yAxis  = { left = { min = 0, max = 1 } }
          annotations = {
            horizontal = [{ value = 1, label = "Running", color = "#2ca02c" }]
          }
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 6
        width  = 8
        height = 6
        properties = {
          title  = "API Request Count"
          region = var.region
          metrics = [[
            "CSG/API", "RequestCount",
            { stat = "Sum", period = 60, color = "#1f77b4" }
          ]]
          view   = "timeSeries"
          period = 60
        }
      },
      {
        type   = "metric"
        x      = 8
        y      = 6
        width  = 8
        height = 6
        properties = {
          title  = "API Error Count"
          region = var.region
          metrics = [[
            "CSG/API", "ErrorCount",
            { stat = "Sum", period = 60, color = "#d62728" }
          ]]
          view   = "timeSeries"
          period = 60
        }
      },
      {
        type   = "metric"
        x      = 16
        y      = 6
        width  = 8
        height = 6
        properties = {
          title  = "API Latency (ms)"
          region = var.region
          metrics = [
            ["CSG/API", "LatencyMs", { stat = "p50", period = 60, label = "p50", color = "#2ca02c" }],
            ["CSG/API", "LatencyMs", { stat = "p95", period = 60, label = "p95", color = "#ff7f0e" }],
            ["CSG/API", "LatencyMs", { stat = "p99", period = 60, label = "p99", color = "#d62728" }]
          ]
          view   = "timeSeries"
          period = 60
        }
      }
    ]
  })
}
