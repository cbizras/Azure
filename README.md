Overview

This PowerShell script uses Azure Resource Graph (ARG) to produce a comprehensive inventory of resources across one or more Azure subscriptions, including common IaaS and PaaS services. It runs a set of Kusto (KQL) queries, returns results in memory, and optionally exports them to CSV or JSON for your own use.

Note: Resource types and schemas can evolve. The queries were designed based on information available up to September 2024.

Prerequisites

PowerShell 7+ (recommended)
Azure modules:
Az.Accounts
Az.ResourceGraph
Azure access:
Reader role (or higher) on the subscriptions you want to inventory
The script auto-installs required modules for the current user if they’re missing.

Installation

Save the script as Get-AzureInventory.ps1.
Open a PowerShell terminal with access to Azure (e.g., pwsh).
Optional manual module install:

Install-Module Az.Accounts -Scope CurrentUser
Install-Module Az.ResourceGraph -Scope CurrentUser
Usage
Run across all accessible subscriptions:

pwsh .\Get-AzureInventory.ps1
Run for specific subscriptions and export to CSV:

pwsh .\Get-AzureInventory.ps1 -Subscriptions @('SUB-ID-1','SUB-ID-2') -Export Csv -OutputDir .\out
Export to JSON:

pwsh .\Get-AzureInventory.ps1 -Export Json -OutputDir .\out
Note: I cannot create files for you, but the script includes export commands that you can run locally.

Parameters

-Subscriptions <string[]>

One or more subscription IDs to scope the queries.

If omitted, the script queries all subscriptions you can access.

-Export <None|Csv|Json>

Output format for exports. Default: None (no files written).

-OutputDir <string>

Directory for exported files. Default: current directory (.).

-PageSize <int>

Page size for ARG query batching. Default: 5000.

Inventories

General: all resources, counts by type/provider, subscriptions/resource groups
Compute: VMs, VM scale sets
Containers: AKS clusters
App Service: Web Apps, Function Apps
Storage: Storage accounts
Databases: SQL servers/databases, SQL Managed Instances, PostgreSQL/MySQL Flexible Servers, Cosmos DB
Networking: VNets, subnets, public IPs, load balancers, app gateways, firewalls
Identity/Secrets: Key Vaults, user/system-assigned identities
Messaging/Integration: Service Bus, Event Hubs, Logic Apps, Event Grid
Monitoring: Application Insights, Log Analytics workspaces
Data/ML: Data Factory, Synapse, Machine Learning workspaces, Databricks
Other PaaS: API Management, App Configuration, Container Apps (environments/apps), Container Registry, Redis Cache, SignalR/Web PubSub, Front Door/CDN profiles, Media Services, Cognitive Search, Maps, Service Fabric
Governance: Role assignments, policy assignments, resource locks
Backup/Recovery: Recovery Services vaults

Outputs

In-memory: a hashtable ($Results) keyed by query name, each holding the result rows.

Optional files:

CSV or JSON files per query, named with a timestamp in the specified -OutputDir.

Customization

Add or modify KQL in the $Queries hashtable.

Filter by tags or location (for example, | where tags['Environment'] =~ 'Prod').

Extend project clauses to include extra properties relevant to your environment.

Permissions

Most resource queries require Reader at subscription scope.

Governance and identity queries may need broader visibility depending on your tenant setup.

Troubleshooting

No results returned:

Confirm you’re authenticated: Connect-AzAccount.

Check that you have Reader access to the targeted subscriptions.

Errors about modules:

Run Install-Module Az.Accounts, Az.ResourceGraph -Scope CurrentUser.

Large environments:

Increase -PageSize or ensure sufficient memory; the script pages via -Skip.

Notes and limitations

ARG reflects ARM-managed resources. Some service internals (e.g., resource-level configurations not exposed via ARM) may require service-specific APIs or SDKs.

Review and adjust queries if you encounter schema differences.

For management group scope, you can adapt the call to Search-AzGraph to use -ManagementGroupName.
