Connect-MgGraph -Scopes "Application.Read.All"

#Define list of high risk permissions
$highRiskPermissions = @(
    "Directory.ReadWrite.All",
    "RoleManagement.ReadWrite.Directory",
    "Application.ReadWrite.All",
    "User.ReadWrite.All",
    "Group.ReadWrite.All",
    "Mail.Read",
    "Mail.ReadWrite",
    "Sites.FullControl.All"
)

#Define files
$BaselineFile = ".\eaapproles.000.csv"
$CurrentFile = ".\eaapproles.current.csv"
$DiffFile = ".\eaapproles.differences.csv"

# Use this to pull all Service Principals
$servicePrincipals = Get-MgServicePrincipal -All

# Use this to limit scope for testing
# $servicePrincipals = Get-MgServicePrincipal -Filter "displayname eq 'Sharegate Apricot'"

$results = foreach ($sp in $servicePrincipals) {

    $assignments = Get-MgServicePrincipalAppRoleAssignment `
        -ServicePrincipalId $sp.Id

    foreach ($assignment in $assignments) {

        $resourceSp = Get-MgServicePrincipal `
            -ServicePrincipalId $assignment.ResourceId

        $role = $resourceSp.AppRoles |
            Where-Object { $_.Id -eq $assignment.AppRoleId } | Sort-Object DisplayName

        if ($role.Value -in $highRiskPermissions) {

            [PSCustomObject]@{
                AppName = $sp.DisplayName
                AppId = $sp.AppId
                Permission = $role.Value
                Resource = $resourceSp.DisplayName
            }
        }
    }
}

# Export results to $CurrentFile
$results | Export-Csv -Path $CurrentFile -NoTypeInformation -Encoding UTF8

# Load the current snapshot back in so we're comparing like-for-like CSV data
$currentApps = Import-Csv $CurrentFile

# Verify baseline exists
if (-not (Test-Path $BaselineFile)) {
    Write-Warning "Baseline file '$BaselineFile' not found."
    Write-Host "Creating baseline file from current data..."
    $currentApps | Export-Csv -Path $BaselineFile -NoTypeInformation -Encoding UTF8
    return
}

# Import baseline
$baselineApps = Import-Csv $BaselineFile

function Get-ComparisonKey {
    param(
        [Parameter(Mandatory)] $Item
    )

    return ("{0}|{1}|{2}" -f $Item.AppId, $Item.Permission, $Item.Resource)
}

# Create lookup tables using AppId + Permission + Resource as the unique key
$baselineLookup = @{}
foreach ($app in $baselineApps) {
    $baselineLookup[(Get-ComparisonKey $app)] = $app
}

$currentLookup = @{}
foreach ($app in $currentApps) {
    $currentLookup[(Get-ComparisonKey $app)] = $app
}

$differences = @()

# Find newly granted permissions
foreach ($app in $currentApps) {
    $key = Get-ComparisonKey $app

    if (-not $baselineLookup.ContainsKey($key)) {
        $differences += [PSCustomObject]@{
            ChangeType  = "NEW"
            AppName     = $app.AppName
            AppId       = $app.AppId
            Permission  = $app.Permission
            Resource    = $app.Resource
            PreviousAppName = ""
            PreviousPermission = ""
            PreviousResource = ""
        }
    }
}

# Find removed permissions
foreach ($app in $baselineApps) {
    $key = Get-ComparisonKey $app

    if (-not $currentLookup.ContainsKey($key)) {
        $differences += [PSCustomObject]@{
            ChangeType  = "REMOVED"
            AppName     = $app.AppName
            AppId       = $app.AppId
            Permission  = $app.Permission
            Resource    = $app.Resource
            PreviousAppName = $app.AppName
            PreviousPermission = $app.Permission
            PreviousResource = $app.Resource
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
        Sort-Object ChangeType, AppName, AppId, Permission, Resource |
        Format-Table -AutoSize

    $differences |
        Export-Csv -Path $DiffFile -NoTypeInformation -Encoding UTF8

    Write-Host "Difference report exported to $DiffFile"
}
