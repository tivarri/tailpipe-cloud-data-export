param()

$ErrorActionPreference = 'Stop'

# Connect with managed identity
Connect-AzAccount -Identity | Out-Null

# Get all subscriptions in the tenant
$subscriptions = Get-AzSubscription

$providersToRegister = @(
    'Microsoft.CostManagement',
    'Microsoft.PolicyInsights',
    'Microsoft.CostManagementExports'
)

foreach ($sub in $subscriptions) {
    Write-Output "Processing subscription: $($sub.Name) ($($sub.Id))"

    try {
        Set-AzContext -SubscriptionId $sub.Id -ErrorAction Stop | Out-Null

        foreach ($provider in $providersToRegister) {
            $providerStatus = Get-AzResourceProvider -ProviderNamespace $provider -ErrorAction SilentlyContinue

            if (-not $providerStatus) {
                Write-Output "  Provider $provider not found in subscription"
                continue
            }

            if ($providerStatus.RegistrationState -ne 'Registered') {
                Write-Output "  Registering provider: $provider (current state: $($providerStatus.RegistrationState))"
                Register-AzResourceProvider -ProviderNamespace $provider -ErrorAction Stop | Out-Null
            } else {
                Write-Output "  Provider $provider already registered"
            }
        }
    }
    catch {
        Write-Warning "  Failed to process subscription $($sub.Name): $_"
        continue
    }
}

Write-Output "✅ Provider registration check complete"
