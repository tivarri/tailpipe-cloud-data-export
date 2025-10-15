param()

Import-Module Az.Accounts
Import-Module Az.Resources
Import-Module Az.Billing


$ErrorActionPreference = 'Stop'

# Ensure costmanagement extension is installed and suppress prompts
$env:AZURE_EXTENSION_USE_NO_PROMPT = "true"
$extInstalled = az extension list --query "[?name=='costmanagement']" -o tsv
if (-not $extInstalled) {
    az extension add --name costmanagement --yes --only-show-errors
}

$storageAccount = "tailpipedataexport934b4f"
$containerName = "dataexport"
$blobName = "known_subscriptions.json"
$exportName = "TailpipeDataExport"
$exportFolder = "tailpipe"
$location = "uksouth"


$null = Connect-AzAccount -Identity
az login --identity --allow-no-subscriptions --only-show-errors | Out-Null

# Optional Service Principal fallback (set these as Automation Variables or env vars)
$spAppId  = $env:TP_SPN_APP_ID
$spSecret = $env:TP_SPN_SECRET
if ([string]::IsNullOrWhiteSpace($spAppId))  { try { $spAppId  = Get-AutomationVariable -Name 'TP_SPN_APP_ID'  -ErrorAction SilentlyContinue } catch {} }
if ([string]::IsNullOrWhiteSpace($spSecret)) { try { $spSecret = Get-AutomationVariable -Name 'TP_SPN_SECRET' -ErrorAction SilentlyContinue } catch {} }
$haveSp = (-not [string]::IsNullOrWhiteSpace($spAppId)) -and (-not [string]::IsNullOrWhiteSpace($spSecret))

function Set-AuthForSubscription {
    param(
        [Parameter(Mandatory)] [string] $SubscriptionId,
        [switch] $UseServicePrincipal
    )
    $tenantIdForSub = (Get-AzSubscription -SubscriptionId $SubscriptionId).TenantId
    if ($UseServicePrincipal -and $haveSp) {
        try {
            $sec = (ConvertTo-SecureString $spSecret -AsPlainText -Force)
            $cred = New-Object System.Management.Automation.PSCredential($spAppId, $sec)
            Connect-AzAccount -ServicePrincipal -Tenant $tenantIdForSub -ApplicationId $spAppId -Credential $cred -ErrorAction Stop | Out-Null
            az login --service-principal -u $spAppId -p $spSecret --tenant $tenantIdForSub --allow-no-subscriptions --only-show-errors | Out-Null
            return $true
        } catch {
            Write-Warning ("SP login failed for {0}: {1}" -f $SubscriptionId, $_.Exception.Message)
            return $false
        }
    }
    else {
        try {
            Connect-AzAccount -Identity -Tenant $tenantIdForSub -ErrorAction Stop | Out-Null
            Select-AzSubscription -SubscriptionId $SubscriptionId -ErrorAction Stop | Out-Null
            az login --identity --allow-no-subscriptions --only-show-errors | Out-Null
            return $true
        } catch {
            Write-Warning ("MI login failed for {0}: {1}" -f $SubscriptionId, $_.Exception.Message)
            return $false
        }
    }
}


function Get-SpObjectIdFromAccessToken {
    try {
        $tok = (Get-AzAccessToken -ResourceUrl "https://management.azure.com/").Token
        if (-not $tok) { return $null }
        $parts = $tok.Split('.')
        if ($parts.Length -lt 2) { return $null }
        $payload = $parts[1].Replace('-', '+').Replace('_', '/')
        switch ($payload.Length % 4) { 2 { $payload += '=='} 3 { $payload += '='} default {} }
        $json = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($payload))
        $obj = $null
        try { $obj = $json | ConvertFrom-Json } catch { return $null }
        if ($obj -and $obj.oid) { return [string]$obj.oid }
        return $null
    } catch { return $null }
}

$miObjectId = $null
try {
    $miObjectId = (Get-AzContext).Account.ExtendedProperties["ServicePrincipalObjectId"]
} catch { }
if ([string]::IsNullOrWhiteSpace($miObjectId)) {
    $miObjectId = Get-SpObjectIdFromAccessToken
    if ($miObjectId) {
        Write-Output ("Automation Managed Identity objectId (from token): {0}" -f $miObjectId)
    } else {
        Write-Warning "Could not resolve Automation Managed Identity objectId from context or token. RBAC preflight will be skipped."
    }
} else {
    Write-Output ("Automation Managed Identity objectId (from context): {0}" -f $miObjectId)
}

if ([string]::IsNullOrWhiteSpace($miObjectId)) { $miObjectId = $null }

# === RBAC and error helpers ===
function Test-HasRoleAssignment {
    param(
        [Parameter(Mandatory)] [string] $ObjectId,
        [Parameter(Mandatory)] [string] $RoleName,
        [Parameter(Mandatory)] [string] $Scope
    )
    try {
        $ra = Get-AzRoleAssignment -ObjectId $ObjectId -RoleDefinitionName $RoleName -Scope $Scope -ErrorAction SilentlyContinue
        return [bool]$ra
    } catch { return $null }
}

function Wait-ForRoleAssignment {
    param(
        [Parameter(Mandatory)] [string] $ObjectId,
        [Parameter(Mandatory)] [string] $RoleName,
        [Parameter(Mandatory)] [string] $Scope,
        [int] $TimeoutSeconds = 240,
        [int] $IntervalSeconds = 15
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        if (Test-HasRoleAssignment -ObjectId $ObjectId -RoleName $RoleName -Scope $Scope) { return $true }
        Start-Sleep -Seconds $IntervalSeconds
    } while ((Get-Date) -lt $deadline)
    return $false
}

function Get-WebExceptionBody {
    param($Exception)
    try {
        if ($Exception.ErrorDetails -and $Exception.ErrorDetails.Message) { return $Exception.ErrorDetails.Message }
        $resp = $Exception.Response
        if ($resp -and $resp.GetResponseStream) {
            $sr = New-Object System.IO.StreamReader($resp.GetResponseStream())
            return $sr.ReadToEnd()
        }
    } catch { }
    return $null
}

# === Helpers for Storage (data plane) with AAD ===
function Get-StorageBearerToken {
    param([string]$ResourceUrl = "https://storage.azure.com/")
    try { return (Get-AzAccessToken -ResourceUrl $ResourceUrl).Token }
    catch { throw ("Unable to acquire Storage token: {0}" -f $_.Exception.Message) }
}

function Get-KnownSubscriptionsJson {
    param(
        [Parameter(Mandatory)] [string] $AccountName,
        [Parameter(Mandatory)] [string] $Container,
        [Parameter(Mandatory)] [string] $Blob
    )
    $token = Get-StorageBearerToken
    $date  = [DateTime]::UtcNow.ToString("R")
    $uri   = "https://$AccountName.blob.core.windows.net/$Container/$Blob"
    try {
        $resp = Invoke-WebRequest -UseBasicParsing -Method GET -Uri $uri -Headers @{ Authorization = "Bearer $token"; "x-ms-version" = "2021-12-02"; "x-ms-date" = $date } -ErrorAction Stop
        if ($resp.Content) { return ($resp.Content | ConvertFrom-Json) }
        else { return @() }
    }
    catch {
        # 404 -> treat as empty
        if ($_.Exception.Response -and $_.Exception.Response.StatusCode.value__ -eq 404) { return @() }
        Write-Warning ("Failed to read known_subscriptions.json: {0}" -f $_.Exception.Message)
        return @()
    }
}

function Save-KnownSubscriptionsJson {
    param(
        [Parameter(Mandatory)] [string] $AccountName,
        [Parameter(Mandatory)] [string] $Container,
        [Parameter(Mandatory)] [string] $Blob,
        [Parameter(Mandatory)] $Object
    )
    $token = Get-StorageBearerToken
    $date  = [DateTime]::UtcNow.ToString("R")
    $uri   = "https://$AccountName.blob.core.windows.net/$Container/$Blob"
    $body  = ($Object | ConvertTo-Json -Depth 10)
    try {
        Invoke-WebRequest -UseBasicParsing -Method PUT -Uri $uri -Headers @{ Authorization = "Bearer $token"; "x-ms-version" = "2021-12-02"; "x-ms-date" = $date; "x-ms-blob-type" = "BlockBlob"; "Content-Type" = "application/json" } -Body $body -ErrorAction Stop | Out-Null
        return $true
    }
    catch {
        Write-Warning ("Failed to write known_subscriptions.json (need 'Storage Blob Data Contributor' on storage account for the Automation identity). Error: {0}" -f $_.Exception.Message)
        return $false
    }
}

$subs = Get-AzSubscription | Where-Object { $_.State -eq "Enabled" }

# Resolve the storage account Resource ID without requiring Reader on the host subscription.
# Prefer explicit override via environment or Automation variables; otherwise infer from account name pattern (tailpipedataexport<last6> → matches subscriptionId suffix).
$explicitStorageId = $env:TP_STORAGE_RESOURCE_ID
if ([string]::IsNullOrWhiteSpace($explicitStorageId)) {
    try { $explicitStorageId = Get-AutomationVariable -Name 'TP_STORAGE_RESOURCE_ID' -ErrorAction SilentlyContinue } catch {}
}

if ([string]::IsNullOrWhiteSpace($explicitStorageId) -eq $false) {
    $storageAccountResourceId = $explicitStorageId.Trim()
    $storageSubscriptionId = ($storageAccountResourceId -split '/')[2]
    $storageResourceGroup = ($storageAccountResourceId -split '/')[4]
}
else {
    # Infer host subscription from the last 6 chars of the storage account name (created as tailpipedataexport<last6>)
    $last6 = $storageAccount.Substring($storageAccount.Length - 6)
    $hostSubId = $null
    foreach ($s in $subs) {
        if ($s.Id.ToLower().EndsWith($last6.ToLower())) { $hostSubId = $s.Id; break }
    }
    if (-not $hostSubId) {
        throw "Could not infer the storage host subscription from account name '$storageAccount' (suffix '$last6'). Set Automation variable TP_STORAGE_RESOURCE_ID to the full resourceId, or set STORAGE_SUBSCRIPTION_ID and STORAGE_RESOURCE_GROUP."
    }

    # Optional overrides via env or Automation Variables
    $storSubOverride = $env:STORAGE_SUBSCRIPTION_ID
    if ([string]::IsNullOrWhiteSpace($storSubOverride)) {
        try { $storSubOverride = Get-AutomationVariable -Name 'STORAGE_SUBSCRIPTION_ID' -ErrorAction SilentlyContinue } catch {}
    }
    $storRgOverride = $env:STORAGE_RESOURCE_GROUP
    if ([string]::IsNullOrWhiteSpace($storRgOverride)) {
        try { $storRgOverride = Get-AutomationVariable -Name 'STORAGE_RESOURCE_GROUP' -ErrorAction SilentlyContinue } catch {}
    }

    $storageSubscriptionId = if ($storSubOverride) { $storSubOverride } else { $hostSubId }
    $storageResourceGroup = if ($storRgOverride) { $storRgOverride } else { 'tailpipe-dataexport' }
    $storageAccountResourceId = "/subscriptions/$storageSubscriptionId/resourceGroups/$storageResourceGroup/providers/Microsoft.Storage/storageAccounts/$storageAccount"
}

Write-Output ("Using storage account resourceId: {0}" -f $storageAccountResourceId)

# Load current known subscriptions list (best-effort; continues if forbidden)
$knownSubs = Get-KnownSubscriptionsJson -AccountName $storageAccount -Container $containerName -Blob $blobName
if ($knownSubs -isnot [System.Array]) { $knownSubs = @() }

# Process only subscriptions that are not already in the state file
$subs = $subs | Where-Object { $knownSubs -notcontains $_.Id }
if ($subs.Count -eq 0) {
    Write-Output "No new subscriptions to process (state file already covers all). Run complete."
    return
}
Write-Output ("Processing only-new subscriptions: {0}" -f ([string]::Join(", ", ($subs | ForEach-Object { $_.Id }))))

foreach ($sub in $subs) {
    $subId = $sub.Id
    Write-Output "Checking subscription $subId..."
    $null = Set-AuthForSubscription -SubscriptionId $subId               # MI first
    Select-AzSubscription -SubscriptionId $subId | Out-Null
    $ctx = Get-AzContext
    Write-Output ("Context → tenant: {0}, subscription: {1}" -f $ctx.Tenant.Id, $ctx.Subscription.Id)
    $callerOid = Get-SpObjectIdFromAccessToken
    if ($callerOid) { Write-Output ("Caller oid (current auth): {0}" -f $callerOid) }
    # Ensure providers are registered for THIS subscription
    try { Register-AzResourceProvider -ProviderNamespace Microsoft.CostManagement -ErrorAction SilentlyContinue | Out-Null } catch { }
    try { Register-AzResourceProvider -ProviderNamespace Microsoft.CostManagementExports -ErrorAction SilentlyContinue | Out-Null } catch { }

    # Determine export name now (used for existence check and later PUT)
    $exportNameForSub = "TailpipeDataExport-$($subId.Substring($subId.Length-6))"

    # Build URIs and headers once
    $apiVersion = "2023-08-01"
    $listUri = ("https://management.azure.com/subscriptions/{0}/providers/Microsoft.CostManagement/exports?api-version={1}" -f $subId, $apiVersion)
    $getUri  = ("https://management.azure.com/subscriptions/{0}/providers/Microsoft.CostManagement/exports/{1}?api-version={2}" -f $subId, $exportNameForSub, $apiVersion)

    $armHeaders = @{ "Authorization" = "Bearer $((Get-AzAccessToken -ResourceUrl 'https://management.azure.com/').Token)"; "Accept" = "application/json" }

    $exportExists = $false
    try {
        $resp = Invoke-RestMethod -Method Get -Uri $getUri -Headers $armHeaders -ErrorAction Stop
        if ($resp) { $exportExists = $true }
    } catch {
        # Check status code and error body
        $status = $null
        try { if ($_.Exception.Response) { $status = $_.Exception.Response.StatusCode.value__ } } catch { }
        $msg  = $_.Exception.Message
        $body = Get-WebExceptionBody -Exception $_.Exception
        if ($body) { Write-Warning $body }
        if ($status -eq 404) {
            # Not found -> proceed to create
        }
        elseif ($status -eq 401 -or $status -eq 403 -or $msg -match '401' -or $msg -match '403' -or ($body -match 'Unauthorized' -or $body -match 'RBACAccessDenied')) {
            if ($haveSp) {
                Write-Warning ("No access to query exports on {0} with MI — attempting Service Principal fallback..." -f $subId)
                if (Set-AuthForSubscription -SubscriptionId $subId -UseServicePrincipal) {
                    $callerOid = Get-SpObjectIdFromAccessToken
                    $armHeaders = @{ "Authorization" = "Bearer $((Get-AzAccessToken -ResourceUrl 'https://management.azure.com/').Token)"; "Accept" = "application/json" }
                    try {
                        $resp = Invoke-RestMethod -Method Get -Uri $getUri -Headers $armHeaders -ErrorAction Stop
                        if ($resp) { $exportExists = $true }
                    } catch {
                        $msg2  = $_.Exception.Message
                        $body2 = Get-WebExceptionBody -Exception $_.Exception
                        if ($body2) { Write-Warning $body2 }
                        if ($msg2 -match '401' -or $msg2 -match '403' -or ($body2 -match 'Unauthorized' -or $body2 -match 'RBACAccessDenied')) {
                            Write-Warning ("Still unauthorized on {0} even with SP (oid={1}). Skipping." -f $subId, $callerOid)
                            continue
                        }
                    }
                } else {
                    Write-Warning ("Service Principal fallback failed for {0}. Skipping." -f $subId)
                    continue
                }
            }
            else {
                Write-Warning ("No access to query exports on {0} — skipping (grant Cost Management Contributor on this subscription to the Automation identity {1}, or configure TP_SPN_APP_ID/TP_SPN_SECRET for SP fallback)." -f $subId, $miObjectId)
                continue
            }
        }
        else {
            # Unknown error on GET; proceed to create (PUT will surface the definitive error)
        }
    }

    if ($exportExists) {
        Write-Output "Export '$exportNameForSub' already exists in $subId"
        if ($knownSubs -notcontains $subId) {
            $knownSubs += $subId
            $saved = Save-KnownSubscriptionsJson -AccountName $storageAccount -Container $containerName -Blob $blobName -Object $knownSubs
            if ($saved) { Write-Output "known_subscriptions.json updated with $subId (backfilled)" }
        }
        continue
    }


    # Preflight RBAC: require Cost Management Contributor (or Owner) — best effort only; never skip on inconclusive results
    $subScope = "/subscriptions/$subId"
    if ([string]::IsNullOrWhiteSpace($callerOid)) {
        Write-Warning ("RBAC preflight for {0}: caller objectId not available; proceeding" -f $subId)
    }
    else {
        Write-Output ("RBAC preflight on {0}: checking caller oid {1} at scope {2}" -f $subId, $callerOid, $subScope)
        $hasCMC = Test-HasRoleAssignment -ObjectId $callerOid -RoleName "Cost Management Contributor" -Scope $subScope
        $hasOwner = $false
        if ($hasCMC -ne $true) { $hasOwner = Test-HasRoleAssignment -ObjectId $callerOid -RoleName "Owner" -Scope $subScope }

        if (($hasCMC -ne $true) -and ($hasOwner -ne $true)) {
            Write-Output ("Waiting up to 240s for role assignment propagation on {0}..." -f $subId)
            $waited = $false
            if ($callerOid) { $waited = Wait-ForRoleAssignment -ObjectId $callerOid -RoleName "Cost Management Contributor" -Scope $subScope -TimeoutSeconds 240 -IntervalSeconds 15 }
            if (-not $waited) {
                Write-Warning ("RBAC not confirmed for {0} at {1}; proceeding to attempt export (will 401 if not yet effective)" -f $subId, $subScope)
            }
        }
    }

    # Optional: verify we can see the storage account on the management plane (helpful hint if Reader is missing on host sub)
    $canSeeStorage = $true
    try {
        Select-AzSubscription -SubscriptionId $storageSubscriptionId -ErrorAction Stop
        Get-AzResource -ResourceId $storageAccountResourceId -ErrorAction Stop | Out-Null
    } catch {
        $canSeeStorage = $false
        Write-Warning ("MI may lack Reader on storage account scope {0}; consider granting 'Reader' on {0}" -f $storageAccountResourceId)
    }
    # switch back to target subscription context
    Select-AzSubscription -SubscriptionId $subId | Out-Null

    # Debug: show the current identity info
    Write-Output "=== Debug: Active Identity and Scope Info ==="
    try {
        $azAcct = az account show -o json | ConvertFrom-Json
        Write-Output ("CLI account → user: {0}, tenant: {1}, subscription: {2}" -f $azAcct.user.name, $azAcct.tenantId, $azAcct.id)
    } catch {
        Write-Warning "Unable to run 'az account show'"
    }
    try {
        $tok = Get-AzAccessToken -ResourceUrl "https://management.azure.com/"
        $payload = $tok.Token.Split('.')[1].Replace('-', '+').Replace('_', '/')
        switch ($payload.Length % 4) { 2 { $payload += '=='} 3 { $payload += '='} }
        $json = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($payload))
        $obj = $json | ConvertFrom-Json
        Write-Output ("ARM token oid: {0}" -f $obj.oid)
    } catch {
        Write-Warning "Unable to decode ARM access token for oid"
    }
    Write-Output "=== End Debug ==="

    $scope = "/subscriptions/$subId"
    $rootPath = "tailpipe/subscriptions/$subId"

    # Don't query schema - just use a minimal working configuration
    # The columns will be automatically included based on the Usage export type


    $deliveryInfo = @{
        destination = @{
            type = "AzureBlob"
            resourceId = $storageAccountResourceId
            container = $containerName
            rootFolderPath = $rootPath
        }
    }

    # Simplified export configuration without columns specification
    $startDate = (Get-Date).AddDays(-1).Date.ToUniversalTime().ToString("yyyy-MM-ddT00:00:00Z")
    $endDate = "2099-12-31T00:00:00Z"

    $exportBody = @{
        properties = @{
            deliveryInfo = $deliveryInfo
            definition = @{
                type = "ActualCost"
                timeframe = "MonthToDate"
                dataSet = @{
                    granularity = "Daily"
                }
            }
            schedule = @{
                status = "Active"
                recurrence = "Daily"
                recurrencePeriod = @{
                    from = $startDate
                    to   = $endDate
                }
            }
            format = "Csv"
        }
    }

    $putUri = "https://management.azure.com$($scope)/providers/Microsoft.CostManagement/exports/$($exportNameForSub)?api-version=$apiVersion"

    # WORKAROUND: Role assignment exists but Cost Management service cache takes time to update
    # Test actual API access by trying a GET operation first
    Write-Output "Waiting for Cost Management API permissions to propagate (role assignment cache update)..."
    $apiAccessReady = $false
    $maxRetries = 20  # 20 * 30 = 10 minutes
    $retryCount = 0

    while (-not $apiAccessReady -and $retryCount -lt $maxRetries) {
        Select-AzSubscription -SubscriptionId $subId | Out-Null
        $testToken = (Get-AzAccessToken -ResourceUrl "https://management.azure.com/").Token
        $testHeaders = @{ Authorization = "Bearer $testToken"; "Accept" = "application/json" }

        # Try to list exports - this will fail with 401 until permissions propagate
        try {
            $null = Invoke-RestMethod -Method Get -Uri $listUri -Headers $testHeaders -ErrorAction Stop
            $apiAccessReady = $true
            Write-Output "Cost Management API access confirmed - permissions have propagated"
        } catch {
            $status = $null
            try { if ($_.Exception.Response) { $status = $_.Exception.Response.StatusCode.value__ } } catch { }

            if ($status -eq 401 -or $status -eq 403) {
                $retryCount++
                if ($retryCount -lt $maxRetries) {
                    Write-Output "API still returning 401/403 - waiting 30 seconds for permission propagation... (attempt $retryCount/$maxRetries)"
                    Start-Sleep -Seconds 30
                }
            } else {
                # Different error (e.g., 404 for no exports) means permissions are working
                $apiAccessReady = $true
                Write-Output "Cost Management API access confirmed (received non-auth error, permissions OK)"
            }
        }
    }

    if (-not $apiAccessReady) {
        Write-Warning "Cost Management API permissions did not propagate after 10 minutes for subscription $subId. This is unusual - the role assignment exists but the service cache hasn't updated. Skipping for now - try again later or contact Azure support."
        continue
    }

    # GET worked but PUT might require different/additional permissions
    # The Cost Management Contributor role should include Microsoft.CostManagement/exports/write
    # But there might be additional permissions needed on the storage account

    # Check if the MI has permissions on the storage account
    Write-Output "Verifying storage account permissions for export destination..."
    $storageRoleNeeded = "Storage Blob Data Contributor"
    $storageRoleExists = az role assignment list --assignee $miObjectId --scope $storageAccountResourceId --role $storageRoleNeeded -o json 2>$null | ConvertFrom-Json

    if (-not $storageRoleExists -or $storageRoleExists.Count -eq 0) {
        Write-Warning "Managed Identity $miObjectId does not have '$storageRoleNeeded' role on storage account $storageAccountResourceId. This is required for Cost Management exports to write data. Please assign this role and re-run."
        continue
    }
    Write-Output "Storage account role assignment confirmed"

    # IMPORTANT: Despite having Cost Management Contributor, creating exports requires Contributor or Owner role
    # Check if we have Contributor or Owner on the subscription where the export is being created
    Write-Output "Checking for Contributor or Owner role on target subscription (required for export creation)..."
    $hasContributor = az role assignment list --assignee $miObjectId --scope "/subscriptions/$subId" --role "Contributor" -o json 2>$null | ConvertFrom-Json
    $hasOwner = az role assignment list --assignee $miObjectId --scope "/subscriptions/$subId" --role "Owner" -o json 2>$null | ConvertFrom-Json

    if ((-not $hasContributor -or $hasContributor.Count -eq 0) -and (-not $hasOwner -or $hasOwner.Count -eq 0)) {
        Write-Warning @"
Managed Identity $miObjectId has Cost Management Contributor but lacks Contributor or Owner role on subscription $subId.

Creating Cost Management exports requires one of these roles:
- Contributor (recommended - grants full resource management)
- Owner (grants full access including RBAC)

Please assign one of these roles:
  az role assignment create --assignee $miObjectId --role "Contributor" --scope "/subscriptions/$subId"

Then re-run this runbook.
"@
        continue
    }

    if ($hasOwner -and $hasOwner.Count -gt 0) {
        Write-Output "Owner role confirmed on target subscription $subId"
    } else {
        Write-Output "Contributor role confirmed on target subscription $subId"
    }

    # CROSS-SUBSCRIPTION CHECK: If storage account is in a different subscription, need permissions there too
    if ($storageSubscriptionId -ne $subId) {
        Write-Output "Storage account is in different subscription ($storageSubscriptionId) - checking permissions there..."
        $hasStorageSubContributor = az role assignment list --assignee $miObjectId --scope "/subscriptions/$storageSubscriptionId" --role "Contributor" -o json 2>$null | ConvertFrom-Json
        $hasStorageSubOwner = az role assignment list --assignee $miObjectId --scope "/subscriptions/$storageSubscriptionId" --role "Owner" -o json 2>$null | ConvertFrom-Json

        if ((-not $hasStorageSubContributor -or $hasStorageSubContributor.Count -eq 0) -and (-not $hasStorageSubOwner -or $hasStorageSubOwner.Count -eq 0)) {
            Write-Warning @"
Cross-subscription export detected: Export in subscription $subId writes to storage in subscription $storageSubscriptionId.

Managed Identity $miObjectId needs Contributor or Owner role on BOTH subscriptions:
1. Target subscription (where export is created): $subId - ✅ CONFIRMED
2. Storage subscription (where data is written): $storageSubscriptionId - ❌ MISSING

Please assign one of these roles on the storage subscription:
  az role assignment create --assignee $miObjectId --role "Contributor" --scope "/subscriptions/$storageSubscriptionId"

Then re-run this runbook.
"@
            continue
        }

        if ($hasStorageSubOwner -and $hasStorageSubOwner.Count -gt 0) {
            Write-Output "Owner role confirmed on storage subscription $storageSubscriptionId"
        } else {
            Write-Output "Contributor role confirmed on storage subscription $storageSubscriptionId"
        }
    }

    Write-Output "All required permissions confirmed - waiting for write permissions to propagate to Cost Management service..."

    # Even with Owner role confirmed in RBAC, the Cost Management service cache needs time to update
    # Retry the PUT operation until it succeeds or times out
    $putSuccess = $false
    $putRetries = 0
    $maxPutRetries = 12  # 12 * 15 = 3 minutes
    $bodyJson = $exportBody | ConvertTo-Json -Depth 10 -Compress

    while (-not $putSuccess -and $putRetries -lt $maxPutRetries) {
        Select-AzSubscription -SubscriptionId $subId | Out-Null
        $token = (Get-AzAccessToken -ResourceUrl "https://management.azure.com/").Token
        $headers = @{ Authorization = "Bearer $token"; "Content-Type"="application/json" }

        try {
            Invoke-RestMethod -Method Put -Uri $putUri -Headers $headers -Body $bodyJson -ErrorAction Stop | Out-Null
            $putSuccess = $true
            Write-Output "Export creation succeeded - write permissions have propagated"
        } catch {
            $errStatus = $null
            try { if ($_.Exception.Response) { $errStatus = $_.Exception.Response.StatusCode.value__ } } catch { }

            if ($errStatus -eq 401 -or $errStatus -eq 403) {
                $putRetries++
                if ($putRetries -lt $maxPutRetries) {
                    Write-Output "PUT still returning $errStatus - waiting 15 seconds for write permission propagation... (attempt $putRetries/$maxPutRetries)"
                    Start-Sleep -Seconds 15
                } else {
                    # Final attempt failed
                    Write-Warning ("Failed to create export for {0} after 3 minutes: {1}" -f $subId, $_.Exception.Message)
                    if ($_.ErrorDetails.Message) {
                        Write-Warning ("ErrorDetails: {0}" -f $_.ErrorDetails.Message)
                    }
                    break
                }
            } else {
                # Non-auth error - fail immediately
                Write-Warning ("Failed to create export for {0}: {1}" -f $subId, $_.Exception.Message)
                if ($_.ErrorDetails.Message) {
                    Write-Warning ("ErrorDetails: {0}" -f $_.ErrorDetails.Message)
                }
                break
            }
        }
    }

    if ($putSuccess) {
        Write-Output "Created/updated cost export '$exportNameForSub' for $subId (storage: $storageAccount/$containerName, folder: $rootPath)"
        if ($knownSubs -notcontains $subId) {
            $knownSubs += $subId
            $saved = Save-KnownSubscriptionsJson -AccountName $storageAccount -Container $containerName -Blob $blobName -Object $knownSubs
            if ($saved) { Write-Output "known_subscriptions.json updated with $subId" } else { Write-Warning "Unable to update known_subscriptions.json" }
        }
    } catch {
        Write-Warning ("Failed to create export for {0}: {1}" -f $subId, $_.Exception.Message)

        # Try multiple methods to get error details
        if ($_.ErrorDetails.Message) {
            Write-Warning ("ErrorDetails: {0}" -f $_.ErrorDetails.Message)
        }

        $body = Get-WebExceptionBody -Exception $_.Exception
        if ($body) {
            Write-Warning ("Response Body: {0}" -f $body)
        }

        # Try reading from response stream directly
        if ($_.Exception.Response) {
            try {
                $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
                $reader.BaseStream.Position = 0
                $responseBody = $reader.ReadToEnd()
                if ($responseBody) {
                    Write-Warning ("Stream Response: {0}" -f $responseBody)
                }
            } catch {
                Write-Warning ("Could not read response stream: {0}" -f $_.Exception.Message)
            }
        }

        Write-Warning ("Full error record: {0}" -f ($_ | ConvertTo-Json -Depth 3))
        continue
    }
}

Write-Output "Run complete."
