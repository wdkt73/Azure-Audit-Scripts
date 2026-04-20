#Simple script to check for public access on storage accounts
# Get all subscriptions
$subscriptions = Get-AzSubscription

# Prepare result collection
$allResults = @()

foreach ($sub in $subscriptions) {
    Write-Host "`n🔁 Switching to subscription: $($sub.Name)" -ForegroundColor Cyan
    Set-AzContext -SubscriptionId $sub.Id | Out-Null

    # Get Storage Accounts
    $storageAccounts = Get-AzStorageAccount

    foreach ($sa in $storageAccounts) {
        $saName = $sa.StorageAccountName
        $resourceGroup = $sa.ResourceGroupName
        $location = $sa.Location
        $subscriptionName = $sub.Name
        $subscriptionId = $sub.Id

        Write-Host "`n➡️ Storage Account: $saName in $resourceGroup [$subscriptionName]" -ForegroundColor Yellow

        # Defaults
        $publicAccess = $true
        $exposureLevel = "Unknown"
        $notes = @()

        # Public Network Access
        $publicNetworkAccess = $sa.PublicNetworkAccess
        if (-not $publicNetworkAccess) {
            $publicNetworkAccess = "NotSpecified"
        }

        # Network Rules
        $networkRules = $sa.NetworkRuleSet
        $defaultAction = $networkRules.DefaultAction
        $ipRules = $networkRules.IpRules
        $vnetRules = $networkRules.VirtualNetworkRules

        # Blob public access setting
        $allowBlobPublicAccess = $sa.AllowBlobPublicAccess

        # Private Endpoints
        $privateEndpoints = Get-AzPrivateEndpointConnection `
            -ResourceGroupName $resourceGroup `
            -ServiceName $saName `
            -PrivateLinkResourceType "Microsoft.Storage/storageAccounts" `
            -ErrorAction SilentlyContinue

        $hasPrivateEndpoint = $privateEndpoints -ne $null

        # -----------------------------
        # ADVANCED EXPOSURE LOGIC
        # -----------------------------

        if ($publicNetworkAccess -eq "Disabled") {
            $publicAccess = $false
            $exposureLevel = "Private"
            $notes += "PublicNetworkAccess disabled"
        }
        else {
            if ($defaultAction -eq "Allow") {
                $exposureLevel = "Open"
                $notes += "Firewall default action is Allow (open to internet)"
            }
            elseif ($defaultAction -eq "Deny") {
                if (($ipRules.Count -eq 0) -and ($vnetRules.Count -eq 0)) {
                    $publicAccess = $false
                    $exposureLevel = "Private"
                    $notes += "Firewall deny with no exceptions"
                }
                else {
                    $exposureLevel = "Restricted"
                    $notes += "Firewall enabled with IP/VNet restrictions"
                }
            }

            # Blob public access risk
            if ($allowBlobPublicAccess -eq $true) {
                $notes += "Blob public access enabled"
                if ($exposureLevel -ne "Private") {
                    $notes += "⚠️ Containers may be publicly accessible"
                }
            }

            # Private endpoint influence
            if ($hasPrivateEndpoint) {
                $notes += "Private Endpoint present"

                if ($exposureLevel -eq "Open") {
                    $notes += "⚠️ Still publicly accessible despite private endpoint"
                }
            }
        }

        # Final public flag
        if ($exposureLevel -eq "Private") {
            $publicAccess = $false
        }

        $notesText = $notes -join "; "

        # Output
        Write-Host "   PublicNetworkAccess: $publicNetworkAccess" -ForegroundColor Cyan
        Write-Host "   Exposure Level: $exposureLevel" -ForegroundColor Green
        Write-Host "   Notes: $notesText" -ForegroundColor Gray

        # Add to results
        $allResults += [PSCustomObject]@{
            SubscriptionName        = $subscriptionName
            SubscriptionId          = $subscriptionId
            StorageAccountName      = $saName
            ResourceGroup           = $resourceGroup
            Location                = $location
            PublicNetworkAccess     = $publicNetworkAccess
            PublicAccess            = $publicAccess
            ExposureLevel           = $exposureLevel
            AllowBlobPublicAccess   = $allowBlobPublicAccess
            Notes                   = $notesText
        }
    }
}

# Summary
$allResults | Select-Object SubscriptionName, StorageAccountName, ExposureLevel, PublicAccess, ResourceGroup | Format-Table -AutoSize

# Export
$timestamp = Get-Date -Format "yyyyMMdd-HHmm"
$csvPath = "./storageaccounts-publicaccess-$timestamp.csv"

$allResults | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8

Write-Host "`n✅ CSV report saved to: $csvPath" -ForegroundColor Green