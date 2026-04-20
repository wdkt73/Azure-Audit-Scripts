#Script to iterate through subscriptions and check role assignments
# Log in if not already authenticated
# Connect-AzAccount
# May fail if CAE is triggered

# Get all subscriptions the account has access to
$subscriptions = Get-AzSubscription
#$subscriptions = Get-AzSubscription | Where-Object { $_.Name -like 'p*' }

# Create an empty list to hold all role assignments
$allRoleAssignments = @()

foreach ($sub in $subscriptions) {
    Write-Host "Processing subscription: $($sub.Name)" -ForegroundColor Cyan
    
    # Set the current context to the subscription
    Set-AzContext -SubscriptionId $sub.Id | Out-Null

    # Get role assignments for the current subscription
    $roleAssignments = Get-AzRoleAssignment

    # Add subscription ID to each assignment (for clarity)
    foreach ($assignment in $roleAssignments) {
        $assignment | Add-Member -NotePropertyName SubscriptionId -NotePropertyValue $sub.Id
        $assignment | Add-Member -NotePropertyName SubscriptionName -NotePropertyValue $sub.Name
    }

    # Append to master list
    $allRoleAssignments += $roleAssignments
}

# Export all assignments to CSV
$timestamp = Get-Date -Format "yyyyMMdd-HHmm"
$csvPath = "./roleassignments-audit-$timestamp.csv"
$allRoleAssignments | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
Write-Host "✅ Export complete: $csvPath" -ForegroundColor Green
