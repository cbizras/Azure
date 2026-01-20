<# 
Purpose: Compile comprehensive Azure inventories using Azure Resource Graph (ARG), including PaaS services
Prereqs:
  - PowerShell 7+ recommended
  - Az.Accounts and Az.ResourceGraph modules
    Install-Module Az.Accounts, Az.ResourceGraph -Scope CurrentUser
Usage examples:
  - Run interactively across all accessible subscriptions:
      pwsh .\Get-AzureInventory.ps1
  - Run for specific subscriptions and export to CSV:
      pwsh .\Get-AzureInventory.ps1 -Subscriptions @('00000000-0000-0000-0000-000000000000','11111111-1111-1111-1111-111111111111') -OutputDir .\out -Export Csv
  - Export to JSON:
      pwsh .\Get-AzureInventory.ps1 -Export Json -OutputDir .\out

Note: I can’t generate files for you, but the export commands are included for your use.
#>

param(
  [string[]] $Subscriptions,
  [ValidateSet('None','Csv','Json')]
  [string] $Export = 'None',
  [string] $OutputDir = '.',
  [int] $PageSize = 5000
)

# Ensure modules
if (-not (Get-Module -ListAvailable -Name Az.Accounts)) {
  Write-Host "Installing Az.Accounts..." -ForegroundColor Yellow
  Install-Module Az.Accounts -Scope CurrentUser -Force
}
if (-not (Get-Module -ListAvailable -Name Az.ResourceGraph)) {
  Write-Host "Installing Az.ResourceGraph..." -ForegroundColor Yellow
  Install-Module Az.ResourceGraph -Scope CurrentUser -Force
}

Import-Module Az.Accounts
Import-Module Az.ResourceGraph

# Authenticate
try {
  if (-not (Get-AzContext)) {
    Connect-AzAccount | Out-Null
  }
} catch {
  Write-Error "Authentication failed: $_"
  exit 1
}

# Resolve subscriptions
if (-not $Subscriptions -or $Subscriptions.Count -eq 0) {
  $Subscriptions = (Get-AzSubscription | Select-Object -ExpandProperty Id)
  Write-Host "Using all accessible subscriptions ($($Subscriptions.Count))." -ForegroundColor Cyan
} else {
  Write-Host "Using specified subscriptions ($($Subscriptions.Count))." -ForegroundColor Cyan
}

# Helper: Run ARG query with paging
function Invoke-ArgPagedQuery {
  param(
    [Parameter(Mandatory=$true)][string] $Query,
    [Parameter(Mandatory=$true)][string[]] $Subs,
    [int] $First = 5000
  )
  $all = @()
  $skip = 0
  while ($true) {
    $res = Search-AzGraph -Query $Query -Subscription $Subs -First $First -Skip $skip
    if (-not $res -or $res.Count -eq 0) { break }
    $all += $res
    if ($res.Count -lt $First) { break }
    $skip += $First
  }
  return $all
}

# Helper: Export results
function Export-Inventory {
  param(
    [Parameter(Mandatory=$true)][string] $Name,
    [Parameter(Mandatory=$true)] $Data,
    [ValidateSet('None','Csv','Json')][string] $Format,
    [string] $Dir
  )
  if ($Format -eq 'None') { return }
  if (-not (Test-Path -Path $Dir)) {
    New-Item -ItemType Directory -Path $Dir | Out-Null
  }
  $ts = (Get-Date).ToString('yyyyMMdd-HHmmss')
  switch ($Format) {
    'Csv'  { $path = Join-Path $Dir "$Name-$ts.csv";  $Data | Export-Csv -Path $path -NoTypeInformation }
    'Json' { $path = Join-Path $Dir "$Name-$ts.json"; $Data | ConvertTo-Json -Depth 8 | Set-Content -Path $path }
  }
  Write-Host "Exported $Name -> $path" -ForegroundColor Green
}

# KQL queries (original coverage + added PaaS services)
$Queries = [ordered]@{
  # General
  'AllResources' = @'
resources
| project name, type, kind, location, resourceGroup, subscriptionId, tags, skuName=tostring(sku.name)
'@

  'CountByType' = @'
resources
| summarize count() by type
| order by count_ desc
'@

  'ProviderCounts' = @'
resources
| extend provider = tostring(split(type, "/")[0])
| summarize count() by provider
| order by count_ desc
'@

  'SubscriptionsAndRGs' = @'
resourcecontainers
| where type in ('microsoft.resources/subscriptions','microsoft.resources/resourcegroups')
| project type, name, subscriptionId, location
'@

  # Compute
  'VMs' = @'
resources
| where type =~ "microsoft.compute/virtualmachines"
| project name, resourceGroup, subscriptionId, location,
          vmSize=tostring(properties.hardwareProfile.vmSize),
          osType=tostring(properties.storageProfile.osDisk.osType),
          zones=iff(isnull(zones),"", strcat_array(zones, ",")),
          identityType=tostring(identity.type),
          tags
'@

  'VMScaleSets' = @'
resources
| where type =~ "microsoft.compute/virtualmachinescalesets"
| project name, resourceGroup, subscriptionId, location,
          skuName=tostring(sku.name), capacity=tostring(sku.capacity),
          identityType=tostring(identity.type), tags
'@

  # Containers (AKS)
  'AKSClusters' = @'
resources
| where type =~ "microsoft.containerservice/managedclusters"
| project name, resourceGroup, subscriptionId, location,
          kubernetesVersion=tostring(properties.kubernetesVersion),
          nodeResourceGroup=tostring(properties.nodeResourceGroup),
          networkPlugin=tostring(properties.networkProfile.networkPlugin),
          privateCluster=tobool(properties.apiServerAccessProfile.enablePrivateCluster),
          tags
'@

  # App Service / Functions
  'WebApps' = @'
resources
| where type =~ "microsoft.web/sites" and (kind !contains "functionapp")
| project name, resourceGroup, subscriptionId, location, kind, skuTier=tostring(sku.tier), tags
'@

  'FunctionApps' = @'
resources
| where type =~ "microsoft.web/sites" and kind contains "functionapp"
| project name, resourceGroup, subscriptionId, location, kind, skuTier=tostring(sku.tier), tags
'@

  # Storage
  'StorageAccounts' = @'
resources
| where type =~ "microsoft.storage/storageaccounts"
| project name, resourceGroup, subscriptionId, location,
          skuName=tostring(sku.name), skuTier=tostring(sku.tier),
          httpsOnly=tobool(properties.supportsHttpsTrafficOnly),
          allowBlobPublicAccess=tostring(properties.allowBlobPublicAccess),
          tags
'@

  # Databases (SQL Server + DBs)
  'SqlServers' = @'
resources
| where type =~ "microsoft.sql/servers"
| project server=name, resourceGroup, subscriptionId, location, tags
'@

  'SqlDatabases' = @'
resources
| where type =~ "microsoft.sql/servers/databases"
| project database=name, resourceGroup, subscriptionId, location,
          skuName=tostring(sku.name), tags
'@

  # Cosmos DB
  'CosmosDbAccounts' = @'
resources
| where type =~ "microsoft.documentdb/databaseaccounts"
| project name, resourceGroup, subscriptionId, location,
          kind, consistency=tostring(properties.consistencyPolicy.defaultConsistencyLevel),
          tags
'@

  # Networking
  'VirtualNetworks' = @'
resources
| where type =~ "microsoft.network/virtualnetworks"
| project name, resourceGroup, subscriptionId, location, addressSpace=tostring(properties.addressSpace.addressPrefixes), tags
'@

  'Subnets' = @'
resources
| where type =~ "microsoft.network/virtualnetworks"
| mv-expand subnet = properties.subnets
| project vnet=name, subnetName=tostring(subnet.name),
          addressPrefix=tostring(subnet.properties.addressPrefix),
          resourceGroup, subscriptionId, location
'@

  'NetInfra' = @'
resources
| where type in~ ("microsoft.network/publicipaddresses",
                  "microsoft.network/loadbalancers",
                  "microsoft.network/applicationgateways",
                  "microsoft.network/azurefirewalls")
| project name, type, resourceGroup, subscriptionId, location, skuName=tostring(sku.name), tags
'@

  # Identity and secrets
  'KeyVaults' = @'
resources
| where type =~ "microsoft.keyvault/vaults"
| project name, resourceGroup, subscriptionId, location,
          purgeProtection=tobool(properties.enablePurgeProtection),
          softDelete=tobool(properties.enableSoftDelete),
          privateEndpointCount=array_length(properties.privateEndpointConnections),
          tags
'@

  'UserAssignedManagedIdentities' = @'
resources
| where type =~ "microsoft.managedidentity/userassignedidentities"
| project name, resourceGroup, subscriptionId, location, tags
'@

  'SystemAssignedIdentities' = @'
resources
| project name, type, resourceGroup, subscriptionId, location, identityType=tostring(identity.type)
| where identityType =~ "SystemAssigned" or identityType =~ "SystemAssigned,UserAssigned"
'@

  # Messaging and integration (Service Bus, Event Hubs, Logic Apps)
  'MessagingIntegration' = @'
resources
| where type in~ ("microsoft.servicebus/namespaces",
                  "microsoft.eventhub/namespaces",
                  "microsoft.logic/workflows")
| project name, type, resourceGroup, subscriptionId, location, tags
'@

  # Backup / recovery
  'RecoveryServicesVaults' = @'
resources
| where type =~ "microsoft.recoveryservices/vaults"
| project name, resourceGroup, subscriptionId, location, tags
'@

  # Governance
  'RoleAssignments' = @'
resources
| where type =~ "microsoft.authorization/roleassignments"
| project name,
          scope=tostring(properties.scope),
          roleDefinitionId=tostring(properties.roleDefinitionId),
          principalId=tostring(properties.principalId),
          principalType=tostring(properties.principalType),
          subscriptionId
'@

  'PolicyAssignments' = @'
resources
| where type =~ "microsoft.authorization/policyassignments"
| project name,
          scope=tostring(properties.scope),
          displayName=tostring(properties.displayName),
          policyDefinitionId=tostring(properties.policyDefinitionId),
          subscriptionId
'@

  'ResourceLocks' = @'
resources
| where type =~ "microsoft.authorization/locks"
| project name,
          level=tostring(properties.level),
          scope=tostring(properties.scope),
          subscriptionId
'@

  # -------------------------
  # Added PaaS service coverage
  # -------------------------

  'ApiManagement' = @'
resources
| where type =~ "microsoft.apimanagement/service"
| project name, resourceGroup, subscriptionId, location,
          sku=tostring(sku.name), publisherEmail=tostring(properties.publisherEmail), tags
'@

  'AppConfiguration' = @'
resources
| where type =~ "microsoft.appconfiguration/configurationstores"
| project name, resourceGroup, subscriptionId, location, sku=tostring(sku.name), tags
'@

  'ContainerAppsEnvAndApps' = @'
resources
| where type in~ ("microsoft.app/managedenvironments","microsoft.app/containerapps")
| project name, type, resourceGroup, subscriptionId, location, tags
'@

  'ContainerRegistry' = @'
resources
| where type =~ "microsoft.containerregistry/registries"
| project name, resourceGroup, subscriptionId, location,
          sku=tostring(sku.name), adminUserEnabled=tobool(properties.adminUserEnabled), tags
'@

  'RedisCache' = @'
resources
| where type =~ "microsoft.cache/redis"
| project name, resourceGroup, subscriptionId, location,
          sku=tostring(sku.name), enableNonSslPort=tobool(properties.enableNonSslPort), tags
'@

  'SignalRAndWebPubSub' = @'
resources
| where type in~ ("microsoft.signalrservice/signalr","microsoft.webpubsub/webpubsub")
| project name, type, resourceGroup, subscriptionId, location, sku=tostring(sku.name), tags
'@

  'CognitiveServices' = @'
resources
| where type =~ "microsoft.cognitiveservices/accounts"
| project name, resourceGroup, subscriptionId, location, kind, sku=tostring(sku.name), tags
'@

  'MachineLearningWorkspaces' = @'
resources
| where type =~ "microsoft.machinelearningservices/workspaces"
| project name, resourceGroup, subscriptionId, location, tags
'@

  'DataFactory' = @'
resources
| where type =~ "microsoft.datafactory/factories"
| project name, resourceGroup, subscriptionId, location, tags
'@

  'SynapseWorkspaces' = @'
resources
| where type =~ "microsoft.synapse/workspaces"
| project name, resourceGroup, subscriptionId, location, tags
'@

  'DatabricksWorkspaces' = @'
resources
| where type =~ "microsoft.databricks/workspaces"
| project name, resourceGroup, subscriptionId, location, sku=tostring(sku.name), tags
'@

  'EventGrid' = @'
resources
| where type in~ ("microsoft.eventgrid/topics","microsoft.eventgrid/domains","microsoft.eventgrid/systemtopics")
| project name, type, resourceGroup, subscriptionId, location, tags
'@

  'AppInsights' = @'
resources
| where type =~ "microsoft.insights/components"
| project name, resourceGroup, subscriptionId, location, applicationType=tostring(properties.Application_Type), tags
'@

  'LogAnalyticsWorkspaces' = @'
resources
| where type =~ "microsoft.operationalinsights/workspaces"
| project name, resourceGroup, subscriptionId, location, tags
'@

  'FrontDoorAndCdnProfiles' = @'
resources
| where type in~ ("microsoft.network/frontdoors","microsoft.cdn/profiles")
| project name, type, resourceGroup, subscriptionId, location, sku=tostring(sku.name), tags
'@

  'MediaServices' = @'
resources
| where type =~ "microsoft.media/mediaservices"
| project name, resourceGroup, subscriptionId, location, tags
'@

  'CognitiveSearch' = @'
resources
| where type =~ "microsoft.search/searchservices"
| project name, resourceGroup, subscriptionId, location, sku=tostring(sku.name), hostingMode=tostring(properties.hostingMode), tags
'@

  'MapsAccounts' = @'
resources
| where type =~ "microsoft.maps/accounts"
| project name, resourceGroup, subscriptionId, location, tags
'@

  'ServiceFabricClusters' = @'
resources
| where type =~ "microsoft.servicefabric/clusters"
| project name, resourceGroup, subscriptionId, location, tags
'@

  'SqlManagedInstances' = @'
resources
| where type =~ "microsoft.sql/managedinstances"
| project name, resourceGroup, subscriptionId, location, tags
'@

  'PostgresMysqlFlexibleServers' = @'
resources
| where type in~ ("microsoft.dbforpostgresql/flexibleservers","microsoft.dbformysql/flexibleservers")
| project name, type, resourceGroup, subscriptionId, location,
          sku=tostring(sku.name), version=tostring(properties.version), tags
'@
}

# Run all queries
$Results = @{}
foreach ($key in $Queries.Keys) {
  Write-Host "Running ARG query: $key ..." -ForegroundColor Magenta
  $data = Invoke-ArgPagedQuery -Query $Queries[$key] -Subs $Subscriptions -First $PageSize
  $Results[$key] = $data
  Export-Inventory -Name $key -Data $data -Format $Export -Dir $OutputDir
}

# Summary
Write-Host "`nInventory complete. Result sets:" -ForegroundColor Cyan
$Results.GetEnumerator() | ForEach-Object {
  "{0}: {1} rows" -f $_.Key, ($_.Value.Count) | Write-Host
}

# Optionally return the hashtable for interactive use
return $Results