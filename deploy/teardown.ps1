<#
.SYNOPSIS
    Terminates the EC2 instance and deletes the security group created by
    deploy.ps1. Reads deploy.state.

.EXAMPLE
    .\teardown.ps1
#>

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
Set-Location -LiteralPath $PSScriptRoot

function Write-Info ($msg) { Write-Host "[teardown] $msg" -ForegroundColor Cyan }

$statePath = Join-Path $PSScriptRoot "deploy.state"
if (-not (Test-Path $statePath)) {
    Write-Host "deploy.state not found - nothing to tear down." -ForegroundColor Yellow
    exit 1
}

# Parse KEY=VALUE state file
$state = @{}
foreach ($line in Get-Content -LiteralPath $statePath) {
    if ($line -match '^\s*([A-Z_]+)=(.*)$') {
        $state[$Matches[1]] = $Matches[2].Trim()
    }
}

$Region     = $state['REGION']
$InstanceId = $state['INSTANCE_ID']
$SgId       = $state['SG_ID']
$SgName     = $state['SG_NAME']

if (-not $InstanceId) { Write-Host "deploy.state malformed - INSTANCE_ID missing." -ForegroundColor Red; exit 1 }

Write-Info "Terminating instance $InstanceId in $Region..."
aws ec2 terminate-instances --region $Region --instance-ids $InstanceId | Out-Null

Write-Info "Waiting for termination..."
aws ec2 wait instance-terminated --region $Region --instance-ids $InstanceId

Write-Info "Deleting security group $SgName ($SgId)..."
# Retry briefly - ENIs sometimes take a moment to detach
$deleted = $false
for ($i = 1; $i -le 5; $i++) {
    try {
        aws ec2 delete-security-group --region $Region --group-id $SgId 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) { $deleted = $true; break }
    } catch { }
    Write-Info "  SG still in use, retrying ($i/5)..."
    Start-Sleep -Seconds 5
}
if (-not $deleted) {
    Write-Warning "Could not delete security group $SgId. Delete it manually if needed."
}

# Key pair is intentionally NOT deleted - keep for future deploys.
# Uncomment to also remove key pair and local .pem:
# aws ec2 delete-key-pair --region $Region --key-name $state['KEY_NAME']
# Remove-Item -LiteralPath (Join-Path $PSScriptRoot "$($state['KEY_NAME']).pem") -ErrorAction SilentlyContinue

Remove-Item -LiteralPath $statePath -ErrorAction SilentlyContinue
Write-Info "Done."
