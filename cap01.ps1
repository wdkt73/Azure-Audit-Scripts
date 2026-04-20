<#
.SYNOPSIS
  Quick audit of Azure AD Conditional Access policies with friendly user/group names.

.DESCRIPTION
  - Connects to Microsoft Graph
  - Exports all CA policies with details
  - Maps GUIDs to user/group names
  - Highlights potential gaps (disabled policies, exclusions, missing MFA, etc.)
#>

# Connect to Graph with required permissions
Connect-MgGraph -Scopes "Policy.Read.All", "Directory.Read.All"

# Get all CA policies
$policies = Get-MgIdentityConditionalAccessPolicy

# Create caches for GUID-to-name lookups
$userCache = @{}
$groupCache = @{}

function Get-UserNameFromId {
    param ($id)
    if (-not $id -or $id -eq "GuestsOrExternalUsers" -or $id -eq "All") {
        return $id
    }

    if ($userCache.ContainsKey($id)) {
        return $userCache[$id]
    }

    try {
        $user = Get-MgUser -UserId $id -ErrorAction Stop
        $userCache[$id] = $user.DisplayName
        return $user.DisplayName
    } catch {
        $userCache[$id] = $id
        return $id
    }
}

function Get-GroupNameFromId {
    param ($id)
    if (-not $id -or $id -eq "All") {
        return $id
    }

    if ($groupCache.ContainsKey($id)) {
        return $groupCache[$id]
    }

    try {
        $group = Get-MgGroup -GroupId $id -ErrorAction Stop
        $groupCache[$id] = $group.DisplayName
        return $group.DisplayName
    } catch {
        $groupCache[$id] = $id
        return $id
    }
}

# Prepare report
$report = @()

foreach ($p in $policies) {
    $includeUserNames = @()
    foreach ($uid in $p.Conditions.Users.IncludeUsers) {
        $includeUserNames += Get-UserNameFromId $uid
    }

    $excludeUserNames = @()
    foreach ($uid in $p.Conditions.Users.ExcludeUsers) {
        $excludeUserNames += Get-UserNameFromId $uid
    }

    $includeGroupNames = @()
    foreach ($gid in $p.Conditions.Users.IncludeGroups) {
        $includeGroupNames += Get-GroupNameFromId $gid
    }

    $excludeGroupNames = @()
    foreach ($gid in $p.Conditions.Users.ExcludeGroups) {
        $excludeGroupNames += Get-GroupNameFromId $gid
    }

    $row = [PSCustomObject]@{
        Name              = $p.DisplayName
        State             = $p.State
        AppliesToUsers    = ($includeUserNames -join ", ")
        ExcludedUsers     = ($excludeUserNames -join ", ")
        AppliesToGroups   = ($includeGroupNames -join ", ")
        ExcludedGroups    = ($excludeGroupNames -join ", ")
        AppliesToApps     = ($p.Conditions.Applications.IncludeApplications -join ", ")
        ExcludedApps      = ($p.Conditions.Applications.ExcludeApplications -join ", ")
        GrantControls     = ($p.GrantControls.BuiltInControls -join ", ")
        SessionControls   = ($p.SessionControls | ConvertTo-Json -Compress)
    }

    $report += $row
}

# Export raw data for documentation
$timestamp = Get-Date -Format "yyyyMMdd-HHmm"
$csvPath = "./CAP-audit-$timestamp.csv"
$report | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
Write-Host "`n✅ CSV report saved to: $csvPath" -ForegroundColor Green




# -------------------------
# Highlight common gaps
# -------------------------
Write-Host "`n🔍 Quick Gap Analysis:`n"

# Disabled policies
$disabled = $report | Where-Object { $_.State -eq "disabled" }
if ($disabled) {
    Write-Host "⚠️ Disabled policies detected:" -ForegroundColor Yellow
    $disabled | Format-Table Name, State
}

# Missing MFA requirement
$noMFA = $report | Where-Object { $_.GrantControls -notmatch "mfa" }
if ($noMFA) {
    Write-Host "`n⚠️ Policies without MFA requirement (check risk):" -ForegroundColor Yellow
    $noMFA | Format-Table Name, GrantControls
}

# Excluded accounts (look for broad exclusions)
$exclusions = $report | Where-Object { $_.ExcludedUsers -or $_.ExcludedGroups }
if ($exclusions) {
    Write-Host "`n⚠️ Policies with user/group exclusions:" -ForegroundColor Yellow
    $exclusions | Format-Table Name, ExcludedUsers, ExcludedGroups
}

# Policies missing AllApps protection
$notAllApps = $report | Where-Object { $_.AppliesToApps -notmatch "All" }
if ($notAllApps) {
    Write-Host "`n⚠️ Policies not covering all apps (review coverage):" -ForegroundColor Yellow
    $notAllApps | Format-Table Name, AppliesToApps
}

Write-Host "`n✅ Review CSV for full details and investigate highlighted gaps."
