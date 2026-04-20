#Simple script to check for public access on logic apps
# Ensure ImportExcel or any other required modules are present (optional if not using Excel)
# CSV doesn't need ImportExcel

# Get all subscriptions
$subscriptions = Get-AzSubscription

# Prepare result collection
$allResults = @()

foreach ($sub in $subscriptions) {
    Write-Host "`n🔁 Switching to subscription: $($sub.Name)" -ForegroundColor Cyan
    Set-AzContext -SubscriptionId $sub.Id | Out-Null

    # Get Logic Apps in this subscription
    $logicApps = Get-AzResource -ResourceType "Microsoft.Logic/workflows" -ExpandProperties

    foreach ($la in $logicApps) {
        $laName = $la.Name
        $resourceGroup = $la.ResourceGroupName
        $location = $la.Location
        $subscriptionName = $sub.Name
        $subscriptionId = $sub.Id
        $laKind = $la.Kind  # For Standard Logic Apps, this is usually 'Stateful' or null

        Write-Host "`n➡️ Logic App: $laName in $resourceGroup [$subscriptionName]" -ForegroundColor Yellow

        # Default values
        $publicAccess = "Unknown"
        $publicNetworkAccess = "Unknown"
        $ipRestrictionDetails = "N/A"
        $privateEndpointDetails = "N/A"
        $logicAppType = "Consumption"

        # Determine if it's Standard Logic App (App Service-based)
        $isStandard = $la.Properties.integrationServiceEnvironment?.Id -ne $null -or $la.Properties.definition -eq $null

        if ($isStandard) {
            $logicAppType = "Standard"
            try {
                # Get related Web App for Standard Logic App
                $webApp = Get-AzWebApp -Name $laName -ResourceGroupName $resourceGroup -ErrorAction Stop

                # Access restrictions
                $accessConfig = Get-AzWebAppAccessRestrictionConfig -ResourceGroupName $resourceGroup -Name $laName -ErrorAction SilentlyContinue
                $restrictions = $accessConfig.MainSiteAccessRestrictions

                $denyAll = $restrictions | Where-Object { $_.Action -eq "Deny" -and $_.IpAddress -eq "Any" }
                $publicAccess = if ($denyAll) { "Disabled" } else { "Enabled" }

                # Format IP restrictions
                $ipRestrictionDetails = if ($restrictions) {
                    $restrictions | ForEach-Object {
                        "- Action: $($_.Action); IP: $($_.IpAddress); Name: $($_.Name); Priority: $($_.Priority); Description: $($_.Description); Tag: $($_.Tag)"
                    } -join "`n"
                } else {
                    "None"
                }

                # publicNetworkAccess
                $laResource = Get-AzResource -ResourceType "Microsoft.Web/sites" -ResourceGroupName $resourceGroup -Name $laName -ExpandProperties -ErrorAction SilentlyContinue
                $publicNetworkAccess = $laResource.Properties.publicNetworkAccess
                if (-not $publicNetworkAccess) {
                    $publicNetworkAccess = "NotSpecified"
                }

                # Private Endpoints
                $privateEndpoints = Get-AzPrivateEndpointConnection `
                    -ResourceGroupName $resourceGroup `
                    -ServiceName $laName `
                    -PrivateLinkResourceType "Microsoft.Web/sites" `
                    -ErrorAction SilentlyContinue

                $privateEndpointDetails = if ($privateEndpoints) {
                    $privateEndpoints | ForEach-Object {
                        "- Connection Name: $($_.Name); Status: $($_.PrivateLinkServiceConnectionState.Status); Description: $($_.PrivateLinkServiceConnectionState.Description)"
                    } -join "`n"
                } else {
                    "None"
                }

            } catch {
                Write-Host "   ⚠️ Error retrieving Web App info for Logic App $laName" -ForegroundColor Red
                $publicAccess = "Error"
            }
        }
        else {
            # Consumption Logic Apps
            $publicAccess = "Always Enabled"
            $publicNetworkAccess = "Not Applicable"
        }

        # Output to console
        Write-Host "   Type: $logicAppType" -ForegroundColor Gray
        Write-Host "   Public Access: $publicAccess" -ForegroundColor Green
        Write-Host "   publicNetworkAccess: $publicNetworkAccess" -ForegroundColor Cyan
        Write-Host "   Private Endpoints:" -ForegroundColor DarkYellow
        Write-Host "$privateEndpointDetails" -ForegroundColor Gray
        Write-Host "   IP Restrictions:" -ForegroundColor Magenta
        Write-Host "$ipRestrictionDetails" -ForegroundColor Gray

        # Add to results
        $allResults += [PSCustomObject]@{
            SubscriptionName       = $subscriptionName
            SubscriptionId         = $subscriptionId
            LogicAppName           = $laName
            ResourceGroup          = $resourceGroup
            Location               = $location
            LogicAppType           = $logicAppType
            PublicAccess           = $publicAccess
            PublicNetworkAccess    = $publicNetworkAccess
            PrivateEndpoints       = $privateEndpointDetails
            IPRestrictions         = $ipRestrictionDetails
        }
    }
}

# Final summary table
$allResults | Select-Object SubscriptionName, LogicAppName, LogicAppType, PublicAccess, PublicNetworkAccess, ResourceGroup | Format-Table -AutoSize

# Export to CSV
$timestamp = Get-Date -Format "yyyyMMdd-HHmm"
$csvPath = "./logicapps-audit-$timestamp.csv"
$allResults | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8

Write-Host "`n✅ CSV report saved to: $csvPath" -ForegroundColor Green
