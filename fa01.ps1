#Simple script to check for public access on function apps
# Get all subscriptions
$subscriptions = Get-AzSubscription

# Prepare result collection
$allResults = @()

foreach ($sub in $subscriptions) {
    Write-Host "`n🔁 Switching to subscription: $($sub.Name)" -ForegroundColor Cyan
    Set-AzContext -SubscriptionId $sub.Id | Out-Null

    # Get Function Apps
    $functionApps = Get-AzWebApp | Where-Object { $_.Kind -like "*functionapp*" }

    foreach ($fa in $functionApps) {
        $faName = $fa.Name
        $resourceGroup = $fa.ResourceGroup
        $location = $fa.Location
        $subscriptionName = $sub.Name
        $subscriptionId = $sub.Id

        Write-Host "`n➡️ Function App: $faName in $resourceGroup [$subscriptionName]" -ForegroundColor Yellow

        # Defaults
        $publicAccess = $true
        $exposureLevel = "Unknown"
        $notes = @()

        # Get full resource
        $faResource = Get-AzResource -ResourceType "Microsoft.Web/sites" `
            -ResourceGroupName $resourceGroup `
            -Name $faName `
            -ExpandProperties

        $publicNetworkAccess = $faResource.Properties.publicNetworkAccess
        if (-not $publicNetworkAccess) {
            $publicNetworkAccess = "NotSpecified"
        }

        # Access Restrictions (Main + SCM)
        $accessConfig = Get-AzWebAppAccessRestrictionConfig `
            -ResourceGroupName $resourceGroup `
            -Name $faName `
            -ErrorAction SilentlyContinue

        $mainRules = $accessConfig.MainSiteAccessRestrictions
        $scmRules = $accessConfig.ScmSiteAccessRestrictions

        # Private Endpoints
        $privateEndpoints = Get-AzPrivateEndpointConnection `
            -ResourceGroupName $resourceGroup `
            -ServiceName $faName `
            -PrivateLinkResourceType "Microsoft.Web/sites" `
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
            # Evaluate IP rules
            if (-not $mainRules -or $mainRules.Count -eq 0) {
                $exposureLevel = "Open"
                $notes += "No IP restrictions (Main site)"
            }
            else {
                $allowAll = $mainRules | Where-Object {
                    $_.Action -eq "Allow" -and ($_.IpAddress -eq "0.0.0.0/0" -or $_.IpAddress -eq "Any")
                }

                $denyAll = $mainRules | Where-Object {
                    $_.Action -eq "Deny" -and $_.IpAddress -eq "Any"
                }

                if ($allowAll) {
                    $exposureLevel = "Open"
                    $notes += "Explicit allow all rule"
                }
                elseif ($denyAll -and $mainRules.Count -eq 1) {
                    $publicAccess = $false
                    $exposureLevel = "Private"
                    $notes += "Deny all rule in place"
                }
                else {
                    $exposureLevel = "Restricted"
                    $notes += "IP restrictions configured"
                }
            }

            # SCM evaluation (important!)
            if (-not $scmRules -or $scmRules.Count -eq 0) {
                $notes += "SCM endpoint unrestricted"
            }

            # Private endpoint influence
            if ($hasPrivateEndpoint) {
                $notes += "Private Endpoint present"

                if ($exposureLevel -eq "Open") {
                    $notes += "⚠️ Still publicly accessible despite private endpoint"
                }
            }
        }

        # Final PublicAccess flag
        if ($exposureLevel -eq "Private") {
            $publicAccess = $false
        }

        # Format notes
        $notesText = $notes -join "; "

        # Output
        Write-Host "   PublicNetworkAccess: $publicNetworkAccess" -ForegroundColor Cyan
        Write-Host "   Exposure Level: $exposureLevel" -ForegroundColor Green
        Write-Host "   Notes: $notesText" -ForegroundColor Gray

        # Add to results
        $allResults += [PSCustomObject]@{
            SubscriptionName    = $subscriptionName
            SubscriptionId      = $subscriptionId
            FunctionAppName     = $faName
            ResourceGroup       = $resourceGroup
            Location            = $location
            PublicNetworkAccess = $publicNetworkAccess
            PublicAccess        = $publicAccess
            ExposureLevel       = $exposureLevel
            Notes               = $notesText
        }
    }
}

# Summary
$allResults | Select-Object SubscriptionName, FunctionAppName, ExposureLevel, PublicAccess, ResourceGroup | Format-Table -AutoSize

# Export
$timestamp = Get-Date -Format "yyyyMMdd-HHmm"
$csvPath = "./functionapps-publicaccess-$timestamp.csv"

$allResults | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8

Write-Host "`n✅ CSV report saved to: $csvPath" -ForegroundColor Green