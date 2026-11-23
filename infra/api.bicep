// ClaimSnap - REST API layer: managed connections, the five Logic Apps, diagnostics and alerts.
// Deploy after main.bicep, the SQL scripts and the function code (the function key must exist).

param location string = resourceGroup().location
param evidenceStorageName string
param cosmosAccountName string
param sqlServerName string
param sqlDatabaseName string = 'claimsnapdb'
param functionAppName string
param translatorName string
param workspaceName string = 'log-claimsnap'

@description('Database user created by 01-schema.sql; it can only execute the stored procedures')
param sqlApiUser string = 'claimsnap_api'

@secure()
param sqlApiPassword string

@description('Who gets an email when Logic App runs start failing or spending approaches the budget')
param alertEmail string

@description('Monthly spending limit for this resource group, in the subscription currency')
param monthlyBudget int = 20

@description('Budgets must start on the first day of a month')
param budgetStartDate string = utcNow('yyyy-MM-01')

resource evidenceStorage 'Microsoft.Storage/storageAccounts@2023-05-01' existing = { name: evidenceStorageName }
resource cosmos 'Microsoft.DocumentDB/databaseAccounts@2024-05-15' existing = { name: cosmosAccountName }
resource functionApp 'Microsoft.Web/sites@2023-12-01' existing = { name: functionAppName }
resource translator 'Microsoft.CognitiveServices/accounts@2023-05-01' existing = { name: translatorName }
resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = { name: workspaceName }

// ---------- Managed API connections ----------
resource blobConnection 'Microsoft.Web/connections@2016-06-01' = {
  name: 'azureblob'
  location: location
  properties: {
    displayName: 'Evidence blob storage'
    api: { id: subscriptionResourceId('Microsoft.Web/locations/managedApis', location, 'azureblob') }
    parameterValues: {
      accountName: evidenceStorage.name
      accessKey: evidenceStorage.listKeys().keys[0].value
    }
  }
}

resource sqlConnection 'Microsoft.Web/connections@2016-06-01' = {
  name: 'sql'
  location: location
  properties: {
    displayName: 'ClaimSnap SQL (procedures only)'
    api: { id: subscriptionResourceId('Microsoft.Web/locations/managedApis', location, 'sql') }
    parameterValues: {
      server: '${sqlServerName}${environment().suffixes.sqlServerHostname}'
      database: sqlDatabaseName
      username: sqlApiUser
      password: sqlApiPassword
    }
  }
}

resource cosmosConnection 'Microsoft.Web/connections@2016-06-01' = {
  name: 'documentdb'
  location: location
  properties: {
    displayName: 'Photo metadata (Cosmos DB)'
    api: { id: subscriptionResourceId('Microsoft.Web/locations/managedApis', location, 'documentdb') }
    parameterValues: {
      databaseAccount: cosmos.name
      accessKey: cosmos.listKeys().primaryMasterKey
    }
  }
}

var connections = {
  azureblob: {
    connectionId: blobConnection.id
    connectionName: blobConnection.name
    id: subscriptionResourceId('Microsoft.Web/locations/managedApis', location, 'azureblob')
  }
  sql: {
    connectionId: sqlConnection.id
    connectionName: sqlConnection.name
    id: subscriptionResourceId('Microsoft.Web/locations/managedApis', location, 'sql')
  }
  documentdb: {
    connectionId: cosmosConnection.id
    connectionName: cosmosConnection.name
    id: subscriptionResourceId('Microsoft.Web/locations/managedApis', location, 'documentdb')
  }
}

// ---------- Logic Apps (one per REST operation) ----------
var workflowNames = ['iups', 'rai', 'rips', 'uips', 'dips']
var definitions = {
  iups: loadJsonContent('workflows/iups.json')
  rai: loadJsonContent('workflows/rai.json')
  rips: loadJsonContent('workflows/rips.json')
  uips: loadJsonContent('workflows/uips.json')
  dips: loadJsonContent('workflows/dips.json')
}

var functionParams = {
  functionUrl: { value: 'https://${functionApp.properties.defaultHostName}' }
  functionKey: { value: listKeys('${functionApp.id}/host/default', '2023-12-01').functionKeys.default }
}
var translatorParams = {
  translatorKey: { value: translator.listKeys().key1 }
  translatorRegion: { value: translator.location }
}

resource workflows 'Microsoft.Logic/workflows@2019-05-01' = [for name in workflowNames: {
  name: 'la-claimsnap-${name}'
  location: location
  properties: {
    state: 'Disabled'
    definition: definitions[name]
    parameters: union(
      { '$connections': { value: connections } },
      name == 'iups' ? functionParams : {},
      contains(['iups', 'uips'], name) ? translatorParams : {}
    )
  }
}]

// ---------- Azure Monitor: run history to Log Analytics + failed-run alerts ----------
resource diagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = [for (name, i) in workflowNames: {
  name: 'to-log-analytics'
  scope: workflows[i]
  properties: {
    workspaceId: workspace.id
    logs: [{ category: 'WorkflowRuntime', enabled: true }]
    metrics: [{ category: 'AllMetrics', enabled: true }]
  }
}]

resource actionGroup 'Microsoft.Insights/actionGroups@2023-01-01' = {
  name: 'ag-claimsnap'
  location: 'global'
  properties: {
    groupShortName: 'claimsnap'
    enabled: true
    emailReceivers: [{ name: 'owner', emailAddress: alertEmail, useCommonAlertSchema: true }]
  }
}

resource failedRunAlerts 'Microsoft.Insights/metricAlerts@2018-03-01' = [for (name, i) in workflowNames: {
  name: 'alert-${name}-failed-runs'
  location: 'global'
  properties: {
    description: 'More than 2 failed ${toUpper(name)} runs in 15 minutes'
    severity: 2
    enabled: true
    scopes: [workflows[i].id]
    evaluationFrequency: 'PT5M'
    windowSize: 'PT15M'
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: 'RunsFailed'
          criterionType: 'StaticThresholdCriterion'
          metricName: 'RunsFailed'
          operator: 'GreaterThan'
          threshold: 2
          timeAggregation: 'Total'
        }
      ]
    }
    actions: [{ actionGroupId: actionGroup.id }]
  }
}]

// ---------- Cost control: budget for everything in this resource group ----------
resource budget 'Microsoft.Consumption/budgets@2023-05-01' = {
  name: 'budget-claimsnap'
  properties: {
    category: 'Cost'
    amount: monthlyBudget
    timeGrain: 'Monthly'
    timePeriod: { startDate: budgetStartDate }
    notifications: {
      actual50: { enabled: true, operator: 'GreaterThanOrEqualTo', threshold: 50, thresholdType: 'Actual', contactEmails: [alertEmail] }
      actual80: { enabled: true, operator: 'GreaterThanOrEqualTo', threshold: 80, thresholdType: 'Actual', contactEmails: [alertEmail], contactGroups: [actionGroup.id] }
      forecast100: { enabled: true, operator: 'GreaterThanOrEqualTo', threshold: 100, thresholdType: 'Forecasted', contactEmails: [alertEmail] }
    }
  }
}

output workflowNames array = [for (name, i) in workflowNames: workflows[i].name]

