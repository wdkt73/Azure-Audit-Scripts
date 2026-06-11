# Connect to Microsoft Graph
Connect-MgGraph -Scopes "Application.Read.All"

# File paths
$BaselineFile = ".\enterpriseapplications.000.csv"
$CurrentFile = ".\enterpriseapplications.current.csv"
$DiffFile = ".\enterpriseapplications.differences.csv"

# Get current Enterprise Applications
# Use the filters to remove noise, in particular the WindowsAzureActiveDirectoryIntegratedApp value
$currentApps = Get-MgServicePrincipal -All |
    Where-Object {
        $_.ServicePrincipalType -eq "Application" -and
        $_.Tags -contains "WindowsAzureActiveDirectoryIntegratedApp"
    } |
    Select-Object DisplayName, AppId, Id |
    Sort-Object DisplayName

# Export current snapshot
$currentApps |
    Export-Csv -Path $CurrentFile -NoTypeInformation -Encoding UTF8

Write-Host "Current Enterprise Applications exported to $CurrentFile"

# Verify baseline exists
if (-not (Test-Path $BaselineFile)) {
    Write-Warning "Baseline file '$BaselineFile' not found."
    Write-Host "Creating baseline file from current data..."
    $currentApps | Export-Csv -Path $BaselineFile -NoTypeInformation -Encoding UTF8
    return
}

# Import baseline
$baselineApps = Import-Csv $BaselineFile

# Create lookup tables using AppId as unique key
$baselineLookup = @{}
foreach ($app in $baselineApps) {
    $baselineLookup[$app.AppId] = $app
}

$currentLookup = @{}
foreach ($app in $currentApps) {
    $currentLookup[$app.AppId] = $app
}

$differences = @()

# Find new and modified apps
foreach ($app in $currentApps) {

    if (-not $baselineLookup.ContainsKey($app.AppId)) {

        $differences += [PSCustomObject]@{
            ChangeType = "NEW"
            DisplayName = $app.DisplayName
            AppId       = $app.AppId
            PreviousName = ""
        }
    }
    else {

        $oldApp = $baselineLookup[$app.AppId]

        if ($oldApp.DisplayName -ne $app.DisplayName) {

            $differences += [PSCustomObject]@{
                ChangeType = "RENAMED"
                DisplayName = $app.DisplayName
                AppId       = $app.AppId
                PreviousName = $oldApp.DisplayName
            }
        }
    }
}

# Find removed apps
foreach ($app in $baselineApps) {

    if (-not $currentLookup.ContainsKey($app.AppId)) {

        $differences += [PSCustomObject]@{
            ChangeType = "REMOVED"
            DisplayName = $app.DisplayName
            AppId       = $app.AppId
            PreviousName = ""
        }
    }
}

# Output results
if ($differences.Count -eq 0) {

    Write-Host "No differences detected." -ForegroundColor Green
}
else {

    Write-Host "$($differences.Count) differences detected." -ForegroundColor Yellow

    $differences |
        Sort-Object ChangeType, DisplayName |
        Format-Table -AutoSize

    $differences |
        Export-Csv -Path $DiffFile -NoTypeInformation -Encoding UTF8

    Write-Host "Difference report exported to $DiffFile"
}