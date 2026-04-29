<#
.SYNOPSIS
    Provisions an EC2 instance in us-west-2 that runs the Fashion Similarity
    Search app (Streamlit on :8501) and queries the existing Qdrant collection
    at http://16.144.140.219:6333.

.DESCRIPTION
    PowerShell port of deploy.sh - same behaviour, runs natively on Windows.
    Requires AWS CLI v2 and OpenSSH client (built into Windows 10+).

.PARAMETER Region
    AWS region. Default: us-west-2.

.PARAMETER InstanceType
    EC2 instance type. Default: t3.medium.

.PARAMETER MyIp
    CIDR allowed to reach :8501. Default: 0.0.0.0/0 (open to internet).
    Pass "auto" to detect your current public IP and use it as a /32.

.PARAMETER SshCidr
    CIDR allowed to reach :22. Default: 0.0.0.0/0.

.PARAMETER KeyName
    EC2 key pair name. Created if missing. Default: fashion-search-key.

.PARAMETER SgName
    Security group name. Reused if already exists. Default: fashion-search-sg.

.PARAMETER RepoUrl
    Git repo to clone on the instance. Default: dongyansun/Similarity-search-project.

.PARAMETER RootVolumeGb
    Root EBS volume size in GB. Default: 30.

.EXAMPLE
    .\deploy.ps1
    .\deploy.ps1 -MyIp auto
    .\deploy.ps1 -InstanceType t3.large -Region us-east-1
#>

[CmdletBinding()]
param(
    [string]$Region        = "us-west-2",
    [string]$InstanceType  = "t3.micro",
    [string]$MyIp          = "0.0.0.0/0",
    [string]$SshCidr       = "0.0.0.0/0",
    [string]$KeyName       = "fashion-search-key",
    [string]$SgName        = "fashion-search-sg",
    [string]$TagName       = "fashion-search",
    [string]$RepoUrl       = "https://github.com/dongyansun/Similarity-search-project.git",
    [int]   $RootVolumeGb  = 30
)

$ErrorActionPreference = "Stop"
Set-Location -LiteralPath $PSScriptRoot

function Write-Info ($msg) { Write-Host "[deploy] $msg" -ForegroundColor Cyan }
function Throw-Err  ($msg) { Write-Host "[error] $msg" -ForegroundColor Red; exit 1 }

# --- Prerequisites -----------------------------------------------------------
if (-not (Get-Command aws -ErrorAction SilentlyContinue)) {
    Throw-Err "AWS CLI not found. Install: https://aws.amazon.com/cli/"
}
try {
    aws sts get-caller-identity --region $Region | Out-Null
} catch {
    Throw-Err "AWS credentials not configured. Run: aws configure"
}
if (-not (Test-Path "user-data.sh")) {
    Throw-Err "user-data.sh not found next to deploy.ps1"
}

# --- Resolve MyIp=auto -> real CIDR ------------------------------------------
if ($MyIp -ieq "auto") {
    try {
        $ip = (Invoke-RestMethod -Uri "https://checkip.amazonaws.com" -TimeoutSec 5).Trim()
        $MyIp = "$ip/32"
        Write-Info "Detected public IP: $MyIp"
    } catch {
        Throw-Err "Could not auto-detect public IP. Pass -MyIp explicitly."
    }
}

# --- Resolve latest Ubuntu 22.04 AMI -----------------------------------------
Write-Info "Resolving latest Ubuntu 22.04 LTS AMI in $Region..."
$amiId = aws ec2 describe-images `
    --region $Region `
    --owners 099720109477 `
    --filters "Name=name,Values=ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*" `
              "Name=state,Values=available" `
    --query 'Images | sort_by(@,&CreationDate) | [-1].ImageId' `
    --output text
if ([string]::IsNullOrWhiteSpace($amiId) -or $amiId -eq "None") {
    Throw-Err "Could not resolve Ubuntu AMI"
}
Write-Info "AMI: $amiId"

# --- Key pair ----------------------------------------------------------------
$pemPath = Join-Path $PSScriptRoot "$KeyName.pem"
$keyExists = $false
try {
    aws ec2 describe-key-pairs --region $Region --key-names $KeyName 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) { $keyExists = $true }
} catch { }

if ($keyExists) {
    Write-Info "Key pair '$KeyName' already exists - reusing."
    if (-not (Test-Path $pemPath)) {
        Write-Warning "Local $KeyName.pem not found. SSH will fail until you obtain it."
    }
} else {
    Write-Info "Creating key pair '$KeyName' -> $pemPath"

    # If a stale .pem from a prior run exists with locked ACLs, clear it first
    if (Test-Path $pemPath) {
        Write-Info "Removing stale local pem (resetting ACLs)..."
        icacls $pemPath /reset 2>$null | Out-Null
        Remove-Item -Force -LiteralPath $pemPath -ErrorAction SilentlyContinue
    }

    # Capture key material, then ALWAYS reformat to canonical PEM:
    # AWS CLI on Windows can return PEMs with no newlines, escaped \n, or CRLF
    # depending on locale. Reformatting from raw base64 dodges all three.
    $keyMaterial = aws ec2 create-key-pair `
        --region $Region `
        --key-name $KeyName `
        --query 'KeyMaterial' `
        --output text
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($keyMaterial)) {
        Throw-Err "create-key-pair returned no key material"
    }
    $keyMaterial = ($keyMaterial -join "`n") `
        -replace '\\n', "`n" `
        -replace "`r", ''

    # Pull out body between BEGIN/END markers, re-wrap at 64 chars
    $re = '-{5}BEGIN ([A-Z 0-9]+?)-{5}(.+?)-{5}END \1-{5}'
    $m  = [regex]::Match($keyMaterial, $re,
            [System.Text.RegularExpressions.RegexOptions]::Singleline)
    if (-not $m.Success) {
        Throw-Err "Could not parse PEM markers in create-key-pair output"
    }
    $pemType = $m.Groups[1].Value
    $pemBody = ($m.Groups[2].Value -replace '\s', '')
    $wrapped = ""
    for ($j = 0; $j -lt $pemBody.Length; $j += 64) {
        $len = [Math]::Min(64, $pemBody.Length - $j)
        $wrapped += $pemBody.Substring($j, $len) + "`n"
    }
    $pemFinal = "-----BEGIN $pemType-----`n$wrapped-----END $pemType-----`n"
    [System.IO.File]::WriteAllText($pemPath, $pemFinal, [System.Text.ASCIIEncoding]::new())

    # OpenSSH on Windows refuses to use a key world-readable by other users.
    # Strip inheritance and grant read-only to the current user.
    $me = "$env:USERDOMAIN\$env:USERNAME"
    icacls $pemPath /inheritance:r        | Out-Null
    icacls $pemPath /grant:r "${me}:(R)"  | Out-Null
    icacls $pemPath /remove "BUILTIN\Users" "Authenticated Users" "Everyone" 2>$null | Out-Null
    Write-Info "Locked $KeyName.pem permissions to $me only."
}

# --- Default VPC -------------------------------------------------------------
$vpcId = aws ec2 describe-vpcs `
    --region $Region `
    --filters "Name=is-default,Values=true" `
    --query 'Vpcs[0].VpcId' --output text
if ($vpcId -eq "None" -or [string]::IsNullOrWhiteSpace($vpcId)) {
    Throw-Err "No default VPC in $Region. Create one or set VPC_ID manually."
}
Write-Info "Default VPC: $vpcId"

# --- Security group ----------------------------------------------------------
$sgId = aws ec2 describe-security-groups `
    --region $Region `
    --filters "Name=group-name,Values=$SgName" "Name=vpc-id,Values=$vpcId" `
    --query 'SecurityGroups[0].GroupId' --output text 2>$null

if ($sgId -eq "None" -or [string]::IsNullOrWhiteSpace($sgId)) {
    Write-Info "Creating security group '$SgName'"
    $sgId = aws ec2 create-security-group `
        --region $Region `
        --group-name $SgName `
        --description "Fashion similarity search - Streamlit on 8501" `
        --vpc-id $vpcId `
        --query 'GroupId' --output text

    aws ec2 authorize-security-group-ingress `
        --region $Region --group-id $sgId `
        --ip-permissions `
            "IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges=[{CidrIp=$SshCidr,Description=ssh}]" `
            "IpProtocol=tcp,FromPort=8501,ToPort=8501,IpRanges=[{CidrIp=$MyIp,Description=streamlit}]" `
        | Out-Null
} else {
    Write-Info "Security group '$SgName' already exists - reusing ($sgId)."
}
Write-Info "Security group: $sgId  (ssh from $SshCidr, :8501 from $MyIp)"

# --- Render user-data with REPO_URL injected --------------------------------
# user-data.sh starts with `#!/bin/bash` on line 1; we need to inject an export
# right after the shebang so it persists into the spawned bash process.
$rendered = New-TemporaryFile
$lines    = Get-Content -LiteralPath "user-data.sh" -Encoding UTF8
$out = New-Object System.Collections.Generic.List[string]
$out.Add("#!/bin/bash")
$out.Add("export REPO_URL='$RepoUrl'")
for ($i = 1; $i -lt $lines.Count; $i++) { $out.Add($lines[$i]) }
# Force LF line endings + UTF-8 WITHOUT BOM (AWS CLI rejects BOM with file://)
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($rendered.FullName, ($out -join "`n"), $utf8NoBom)

# --- Launch the instance -----------------------------------------------------
Write-Info "Launching $InstanceType instance..."
$instanceId = aws ec2 run-instances `
    --region $Region `
    --image-id $amiId `
    --instance-type $InstanceType `
    --key-name $KeyName `
    --security-group-ids $sgId `
    --user-data "fileb://$($rendered.FullName)" `
    --block-device-mappings "DeviceName=/dev/sda1,Ebs={VolumeSize=$RootVolumeGb,VolumeType=gp3,DeleteOnTermination=true}" `
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$TagName}]" `
    --query 'Instances[0].InstanceId' --output text

Remove-Item -LiteralPath $rendered.FullName -ErrorAction SilentlyContinue
Write-Info "Instance: $instanceId"

Write-Info "Waiting for instance to enter 'running' state..."
aws ec2 wait instance-running --region $Region --instance-ids $instanceId

$publicIp = aws ec2 describe-instances `
    --region $Region --instance-ids $instanceId `
    --query 'Reservations[0].Instances[0].PublicIpAddress' --output text

# --- Persist state for teardown.ps1 -----------------------------------------
@"
REGION=$Region
INSTANCE_ID=$instanceId
SG_ID=$sgId
SG_NAME=$SgName
KEY_NAME=$KeyName
PUBLIC_IP=$publicIp
"@ | Set-Content -LiteralPath (Join-Path $PSScriptRoot "deploy.state") -Encoding ascii

Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host "  Fashion Similarity Search - deployed" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host "  Region        : $Region"
Write-Host "  Instance      : $instanceId  ($InstanceType)"
Write-Host "  Public IP     : $publicIp"
Write-Host "  App URL       : http://$publicIp`:8501"
Write-Host "  SSH           : ssh -i $KeyName.pem ubuntu@$publicIp"
Write-Host "  Watch boot    : ssh -i $KeyName.pem ubuntu@$publicIp ``"
Write-Host "                    'sudo tail -f /var/log/cloud-init-output.log'"
Write-Host ""
Write-Host "  Note: first boot takes ~5-8 min (installing torch + CLIP)."
Write-Host "        The app is live once Streamlit prints 'You can now"
Write-Host "        view your Streamlit app in your browser'."
Write-Host ""
Write-Host "  Qdrant target : http://16.144.140.219:6333"
Write-Host "                  collection: deepfashion_items"
Write-Host ""
Write-Host "  Tear down     : .\teardown.ps1"
Write-Host "============================================================" -ForegroundColor Green
