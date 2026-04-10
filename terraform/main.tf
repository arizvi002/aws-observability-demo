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

resource "aws_iam_instance_profile" "ec2" {
  name = "${var.project}-instance-profile"
  role = aws_iam_role.ec2.name
}

# ── EC2: Windows Server t3.micro ─────────────────────────────────────────────
resource "aws_instance" "windows" {
  ami                  = data.aws_ami.windows.id
  instance_type        = var.instance_type
  iam_instance_profile = aws_iam_instance_profile.ec2.name

  # Bootstrap: install CWA, configure, start service-metrics task
  user_data = <<-USERDATA
    <powershell>
    $ErrorActionPreference = "Stop"

    # Install CWA
    $msi = "$env:TEMP\cwa.msi"
    Invoke-WebRequest -Uri "https://s3.amazonaws.com/amazoncloudwatch-agent/windows/amd64/latest/amazon-cloudwatch-agent.msi" -OutFile $msi -UseBasicParsing
    Start-Process msiexec.exe -ArgumentList "/i `"$msi`" /quiet /norestart" -Wait
    Remove-Item $msi -Force

    # Write agent config
    $cfgDir = "C:\ProgramData\Amazon\AmazonCloudWatchAgent"
    New-Item -ItemType Directory -Force -Path $cfgDir | Out-Null
    Invoke-WebRequest -Uri "https://raw.githubusercontent.com/PLACEHOLDER/aws-observability-demo/main/cloudwatch/cwa-config.json" -OutFile "$cfgDir\amazon-cloudwatch-agent.json" -UseBasicParsing

    # Start agent
    & "C:\Program Files\Amazon\AmazonCloudWatchAgent\amazon-cloudwatch-agent-ctl.ps1" -a fetch-config -m ec2 -s -c "file:$cfgDir\amazon-cloudwatch-agent.json"

    # Write service-metrics script and schedule it
    $scriptsDir = "C:\app\scripts"
    New-Item -ItemType Directory -Force -Path $scriptsDir | Out-Null
    New-Item -ItemType Directory -Force -Path "C:\app\logs"   | Out-Null

    $script = @'
    param([string]$Region="us-west-2",[string]$Namespace="CSG/Services",[string]$ServiceName="SMTPSVC")
    try { $svc=$_=Get-Service $ServiceName -EA Stop; $v=if($svc.Status -eq "Running"){1}else{0} } catch { $v=0 }
    try { $tok=Invoke-RestMethod -Method PUT "http://169.254.169.254/latest/api/token" -Headers @{"X-aws-ec2-metadata-token-ttl-seconds"="21600"} -TimeoutSec 2; $id=Invoke-RestMethod "http://169.254.169.254/latest/meta-data/instance-id" -Headers @{"X-aws-ec2-metadata-token"=$tok} -TimeoutSec 2 } catch { $id="unknown" }
    aws cloudwatch put-metric-data --region $Region --namespace $Namespace --metric-data "[{`"MetricName`":`"ServiceRunning`",`"Dimensions`":[{`"Name`":`"InstanceId`",`"Value`":`"$id`"}],`"Value`":$v,`"Unit`":`"Count`"}]"
    '@
    Set-Content "$scriptsDir\service-metrics.ps1" $script -Encoding UTF8

    $action    = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NonInteractive -ExecutionPolicy Bypass -File `"$scriptsDir\service-metrics.ps1`""
    $trigger   = New-ScheduledTaskTrigger -RepetitionInterval (New-TimeSpan -Minutes 1) -Once -At (Get-Date)
    $settings  = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 1) -MultipleInstances IgnoreNew
    $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -RunLevel Highest
    Register-ScheduledTask -TaskName "CWA-ServiceMetrics" -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null
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
        x = 0; y = 0; width = 12; height = 6
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
        x = 12; y = 0; width = 12; height = 6
        properties = {
          title  = "SMTPSVC ServiceRunning"
          region = var.region
          metrics = [[
            "CSG/Services", "ServiceRunning",
            "InstanceId", aws_instance.windows.id,
            { stat = "Minimum", period = 60, color = "#d62728" }
          ]]
          view       = "timeSeries"
          period     = 60
          yAxis      = { left = { min = 0, max = 1 } }
          annotations = {
            horizontal = [{ value = 1, label = "Running", color = "#2ca02c" }]
          }
        }
      },
      {
        type   = "metric"
        x = 0; y = 6; width = 8; height = 6
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
        x = 8; y = 6; width = 8; height = 6
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
        x = 16; y = 6; width = 8; height = 6
        properties = {
          title  = "API Latency (ms)"
          region = var.region
          metrics = [
            [ "CSG/API", "LatencyMs", { stat = "p50",  period = 60, label = "p50",  color = "#2ca02c" } ],
            [ "CSG/API", "LatencyMs", { stat = "p95",  period = 60, label = "p95",  color = "#ff7f0e" } ],
            [ "CSG/API", "LatencyMs", { stat = "p99",  period = 60, label = "p99",  color = "#d62728" } ]
          ]
          view   = "timeSeries"
          period = 60
        }
      }
    ]
  })
}
