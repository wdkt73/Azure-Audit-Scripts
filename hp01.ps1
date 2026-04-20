# wdkt - 17 Mar 26
# Ensure required modules
# Install-Module Az -Scope CurrentUser
# Install-Module Microsoft.Graph -Scope CurrentUser

# Connect to Azure and Microsoft Graph
# Connect-AzAccount
# Connect-MgGraph -Scopes "Directory.Read.All","Group.Read.All","Application.Read.All"

# Ensure required modules
# Install-Module Az -Scope CurrentUser
# Install-Module Microsoft.Graph -Scope CurrentUser

# Define high privilege roles
$HighPrivilegeRoles = @(
    "Owner",
    "User Access Administrator",
    "Contributor"
)

# Risk scoring per role
$RoleRisk = @{
    "Owner" = 5
    "User Access Administrator" = 4
    "Contributor" = 3
}

# Function: Get transitive members of a group
function Get-GroupMembersRecursive {
    param ([string]$GroupId)

    $members = @()
    try {
        $transitiveMembers = Get-MgGroupTransitiveMember -GroupId $GroupId -All
        $members += $transitiveMembers
    } catch {
        Write-Warning "Failed to expand group $GroupId"
    }
    return $members
}

# Function: Check service principal credentials
function Get-SPRiskScore {
    param ([Microsoft.Graph.PowerShell.Models.MicrosoftGraphServicePrincipal]$SP)

    $score = 0
    if ($SP.PasswordCredentials.Count -gt 0) { $score += 2 }
    if ($SP.KeyCredentials.Count -gt 0) { $score += 2 }
    return $score
}

# Initialize results array
$results = @()

# Get all subscriptions in the tenant
$subscriptions = Get-AzSubscription

foreach ($sub in $subscriptions) {
    Write-Host "`nProcessing subscription: $($sub.Name) [$($sub.Id)]"

    # Set context to current subscription
    Set-AzContext -Subscription $sub.Id | Out-Null

    # Get role assignments in this subscription
    $roleAssignments = Get-AzRoleAssignment

    foreach ($assignment in $roleAssignments) {

        if ($HighPrivilegeRoles -notcontains $assignment.RoleDefinitionName) { continue }

        $principalType = $assignment.ObjectType
        $principalId   = $assignment.ObjectId
        $baseScore     = $RoleRisk[$assignment.RoleDefinitionName]

        # Case 1: Direct user or service principal
        if ($principalType -in @("User","ServicePrincipal")) {

            $spScore = 0
            if ($principalType -eq "ServicePrincipal") {
                $sp = Get-MgServicePrincipal -ServicePrincipalId $principalId
                $spScore = Get-SPRiskScore -SP $sp
            }

            $results += [PSCustomObject]@{
                Subscription    = $sub.Name
                PrincipalName   = $assignment.DisplayName
                PrincipalType   = $principalType
                Role            = $assignment.RoleDefinitionName
                Scope           = $assignment.Scope
                AssignmentType  = "Direct"
                RiskScore       = $baseScore + $spScore
            }
        }

        # Case 2: Group → expand members
        elseif ($principalType -eq "Group") {

            $members = Get-GroupMembersRecursive -GroupId $principalId

            foreach ($member in $members) {

                $spScore = 0
                if ($member.'@odata.type' -eq "#microsoft.graph.servicePrincipal") {
                    $sp = Get-MgServicePrincipal -ServicePrincipalId $member.Id
                    $spScore = Get-SPRiskScore -SP $sp
                }

                if ($member.'@odata.type' -eq "#microsoft.graph.user" -or
                    $member.'@odata.type' -eq "#microsoft.graph.servicePrincipal") {

                    $results += [PSCustomObject]@{
                        Subscription    = $sub.Name
                        PrincipalName   = $member.DisplayName
                        PrincipalType   = $member.'@odata.type'
                        Role            = $assignment.RoleDefinitionName
                        Scope           = $assignment.Scope
                        AssignmentType  = "Inherited (via Group)"
                        SourceGroup     = $assignment.DisplayName
                        RiskScore       = $baseScore + $spScore
                    }
                }
            }
        }
    }
}

# Timestamp for export
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$csvPath = "HighPrivilegeAccounts_AllSubs_$timestamp.csv"

# Sort by risk score descending, then role and principal name
$results | Sort-Object -Property "RiskScore","Role","PrincipalName" -Descending | Format-Table -AutoSize

# Export to CSV
$results | Export-Csv -Path $csvPath -NoTypeInformation

Write-Host "`nDone. High-risk accounts exported to $csvPath"