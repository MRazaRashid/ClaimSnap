// ClaimSnap - core resources: storage, databases, function, translator and monitoring.
// Deploy first; api.bicep (connections + Logic Apps) is deployed after the function code.

param location string = resourceGroup().location

@description('SQL server admin login (used only to run the schema scripts)')
param sqlAdminLogin string = 'claimsnapadmin'

@secure()
param sqlAdminPassword string

@description('Your public IP, so you can run the schema scripts with sqlcmd. Leave empty to use the portal Query editor.')
param clientIp string = ''

@description('Azure SQL free offer (100,000 vCore seconds a month, then pauses). Available on paid subscriptions; set false if the subscription already uses it.')
param sqlFreeOffer bool = true

@description('Cosmos DB free tier (first 1,000 RU/s free). One account per subscription; set true if no other account uses it.')
param cosmosFreeTier bool = false

@description('F0 = free 2M characters/month, one per subscription. Use S1 (pay per character) if an F0 resource already exists.')
@allowed(['F0', 'S1'])
param translatorSku string = 'F0'

@description('Extra origins allowed to read photos from Blob (local testing)')
param extraCorsOrigins array = ['http://localhost:5500', 'http://127.0.0.1:5500']

var suffix = take(uniqueString(resourceGroup().id), 6)
var names = {
  evidenceStorage: 'stclaimsnap${suffix}'
  webStorage: 'stclaimsnapweb${suffix}'
  sqlServer: 'sql-claimsnap-${suffix}'
  sqlDatabase: 'claimsnapdb'
  cosmos: 'cosmos-claimsnap-${suffix}'
  functionApp: 'func-claimsnap-${suffix}'
  translator: 'tr-claimsnap-${suffix}'
  workspace: 'log-claimsnap'
  appInsights: 'appi-claimsnap'
}

// ---------- Monitoring ----------
resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: names.workspace
  location: location
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: 30
  }
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: names.appInsights
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: workspace.id
  }
}

// ---------- Static website + function host storage ----------
resource webStorage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: names.webStorage
  location: location
  kind: 'StorageV2'
  sku: { name: 'Standard_LRS' }
  properties: {
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    allowBlobPublicAccess: false
  }
}

// ---------- Evidence storage (private, zone-redundant) ----------
resource evidenceStorage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: names.evidenceStorage
  location: location
  kind: 'StorageV2'
  sku: { name: 'Standard_ZRS' }
  properties: {
    accessTier: 'Hot'
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    allowBlobPublicAccess: false
  }
}

var webEndpoint = webStorage.properties.primaryEndpoints.web

resource evidenceBlob 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: evidenceStorage
  name: 'default'
  properties: {
    deleteRetentionPolicy: { enabled: true, days: 30 }
    containerDeleteRetentionPolicy: { enabled: true, days: 30 }
    cors: {
      corsRules: [
        {
          // Lets the adjuster console download a photo to re-check its SHA-256
          allowedOrigins: concat([substring(webEndpoint, 0, max(0, length(webEndpoint) - 1))], extraCorsOrigins)
          allowedMethods: ['GET', 'HEAD']
          allowedHeaders: ['*']
          exposedHeaders: ['*']
          maxAgeInSeconds: 3600
        }
      ]
    }
  }
}

resource evidenceContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: evidenceBlob
  name: 'evidence-originals'
  properties: { publicAccess: 'None' }
}

// Older evidence moves to cheaper tiers. Archive is not available on ZRS, so Cold is used instead.
resource lifecycle 'Microsoft.Storage/storageAccounts/managementPolicies@2023-05-01' = {
  parent: evidenceStorage
  name: 'default'
  properties: {
    policy: {
      rules: [
        {
          name: 'tier-old-evidence'
          enabled: true
          type: 'Lifecycle'
          definition: {
            filters: { blobTypes: ['blockBlob'], prefixMatch: ['evidence-originals/claims/'] }
            actions: {
              baseBlob: {
                tierToCool: { daysAfterModificationGreaterThan: 30 }
                tierToCold: { daysAfterModificationGreaterThan: 90 }
              }
            }
          }
        }
      ]
    }
  }
}

// ---------- Azure SQL (relational core) ----------
resource sqlServer 'Microsoft.Sql/servers@2023-08-01-preview' = {
  name: names.sqlServer
  location: location
  properties: {
    administratorLogin: sqlAdminLogin
    administratorLoginPassword: sqlAdminPassword
    minimalTlsVersion: '1.2'
    publicNetworkAccess: 'Enabled'
  }
}

resource allowAzure 'Microsoft.Sql/servers/firewallRules@2023-08-01-preview' = {
  parent: sqlServer
  name: 'AllowAllWindowsAzureIps'
  properties: { startIpAddress: '0.0.0.0', endIpAddress: '0.0.0.0' }
}

resource allowClient 'Microsoft.Sql/servers/firewallRules@2023-08-01-preview' = if (!empty(clientIp)) {
  parent: sqlServer
  name: 'client'
  properties: { startIpAddress: clientIp, endIpAddress: clientIp }
}

resource sqlDatabase 'Microsoft.Sql/servers/databases@2023-08-01-preview' = {
  parent: sqlServer
  name: names.sqlDatabase
  location: location
  sku: { name: 'GP_S_Gen5', tier: 'GeneralPurpose', family: 'Gen5', capacity: 2 }
  properties: union({
    autoPauseDelay: 60
    minCapacity: json('0.5')
    requestedBackupStorageRedundancy: 'Local'
    useFreeLimit: sqlFreeOffer
  }, sqlFreeOffer ? { freeLimitExhaustionBehavior: 'AutoPause' } : {})
}

// ---------- Cosmos DB (photo metadata) ----------
resource cosmos 'Microsoft.DocumentDB/databaseAccounts@2024-05-15' = {
  name: names.cosmos
  location: location
  kind: 'GlobalDocumentDB'
  properties: {
    databaseAccountOfferType: 'Standard'
    enableFreeTier: cosmosFreeTier
    consistencyPolicy: { defaultConsistencyLevel: 'Session' }
    locations: [{ locationName: location, failoverPriority: 0, isZoneRedundant: false }]
  }
}

resource cosmosDb 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases@2024-05-15' = {
  parent: cosmos
  name: 'evidence'
  properties: { resource: { id: 'evidence' } }
}

resource metadataContainer 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers@2024-05-15' = {
  parent: cosmosDb
  name: 'metadata'
  properties: {
    resource: {
      id: 'metadata'
      partitionKey: { paths: ['/claimId'], kind: 'Hash' }
    }
    // Scales between 100 and 1,000 RU/s with demand
    options: { autoscaleSettings: { maxThroughput: 1000 } }
  }
}

// ---------- Azure AI Translator ----------
resource translator 'Microsoft.CognitiveServices/accounts@2023-05-01' = {
  name: names.translator
  location: location
  kind: 'TextTranslation'
  sku: { name: translatorSku }
  properties: { publicNetworkAccess: 'Enabled' }
}


 // ---------- Azure Functions (Flex Consumption) ----------

var webStorageConnection = 'DefaultEndpointsProtocol=https;AccountName=${webStorage.name};AccountKey=${webStorage.listKeys().keys[0].value};EndpointSuffix=${environment().suffixes.storage}'

// Container for Function App deployment packages
resource functionDeploymentBlob 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: webStorage
  name: 'default'
}

resource functionDeploymentContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: functionDeploymentBlob
  name: 'function-deployments'
  properties: {
    publicAccess: 'None'
  }
}

// Flex Consumption hosting plan
resource plan 'Microsoft.Web/serverfarms@2024-04-01' = {
  name: 'plan-claimsnap'
  location: location
  kind: 'functionapp'
  sku: {
    name: 'FC1'
    tier: 'FlexConsumption'
  }
  properties: {
    reserved: true
    zoneRedundant: false
  }
}

// Node.js 22 Function App
resource functionApp 'Microsoft.Web/sites@2024-04-01' = {
  name: names.functionApp
  location: location
  kind: 'functionapp,linux'
  properties: {
    serverFarmId: plan.id
    httpsOnly: true

    functionAppConfig: {
      deployment: {
        storage: {
          type: 'blobContainer'
          value: '${webStorage.properties.primaryEndpoints.blob}${functionDeploymentContainer.name}'
          authentication: {
            type: 'StorageAccountConnectionString'
            storageAccountConnectionStringName: 'DEPLOYMENT_STORAGE_CONNECTION_STRING'
          }
        }
      }

      scaleAndConcurrency: {
        maximumInstanceCount: 10
        instanceMemoryMB: 2048
      }

      runtime: {
        name: 'node'
        version: '22'
      }
    }

    siteConfig: {
      ftpsState: 'Disabled'
      minTlsVersion: '1.2'
      appSettings: [
        {
          name: 'AzureWebJobsStorage'
          value: webStorageConnection
        }
        {
          name: 'DEPLOYMENT_STORAGE_CONNECTION_STRING'
          value: webStorageConnection
        }
        {
          name: 'FUNCTIONS_EXTENSION_VERSION'
          value: '~4'
        }
        {
          name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
          value: appInsights.properties.ConnectionString
        }
      ]
    }
  }
}
