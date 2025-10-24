@description('Name of the environment that can be used as part of naming resource convention')
param environmentName string

@description('The location used for all deployed resources')
param location string = resourceGroup().location

@minLength(1)
@description('The location used for Azure AI Foundry resources')
@allowed([
  'australiaeast'
  'eastus'
  'eastus2'
  'japaneast'
  'koreacentral'
  'southindia'
  'swedencentral'
  'switzerlandnorth'
  'uksouth'
])
param aifLocation string

@description('Tags that will be applied to all resources')
param tags object = {}

param mcpTodoClientAppExists bool
param mcpTodoServerAppExists bool

@description('Id of the user or app to assign application roles')
param principalId string

@description('Whether to use the built-in login feature for the application or not')
param useLogin bool = true

@description('The SKU for the Azure OpenAI resource')
@allowed([
  'S0'
])
param aifSkuName string = 'S0'
@description('GPT model to deploy')
param gptModelName string = 'gpt-5-mini'
@description('GPT model version')
param gptModelVersion string = '2025-08-07'
@description('GPT deployment capacity')
param gptCapacity int = 10

@description('The JWT audience for auth.')
@secure()
param jwtAudience string = ''
@description('The JWT issuer for auth.')
@secure()
param jwtIssuer string = ''
@description('The JWT expiry for auth.')
@secure()
param jwtExpiry string = ''
@description('The JWT secret for auth.')
@secure()
param jwtSecret string = ''
@description('The JWT token for auth.')
@secure()
param jwtToken string = ''

@description('Enable development mode for MCP server')
param enableMcpServerDevelopmentMode bool

param mcpServerIngressPort int = 3000
param mcpClientIngressPort int = 8080

param mcpServerIngressExternal bool = false

var abbrs = loadJsonContent('./abbreviations.json')
var resourceToken = uniqueString(subscription().id, resourceGroup().id, location)

// Monitor application with Azure Monitor
module monitoring 'br/public:avm/ptn/azd/monitoring:0.1.0' = {
  name: 'monitoring'
  params: {
    logAnalyticsName: '${abbrs.operationalInsightsWorkspaces}${resourceToken}'
    applicationInsightsName: '${abbrs.insightsComponents}${resourceToken}'
    applicationInsightsDashboardName: '${abbrs.portalDashboards}${resourceToken}'
    location: location
    tags: tags
  }
}

// Azure OpenAI resource
resource openAI 'Microsoft.CognitiveServices/accounts@2025-07-01-preview' = {
  name: '${abbrs.cognitiveServicesAccounts}${resourceToken}'
  location: aifLocation
  kind: 'OpenAI'
  sku: {
    name: aifSkuName
  }
  properties: {
    customSubDomainName: '${abbrs.cognitiveServicesAccounts}${resourceToken}'
    publicNetworkAccess: 'Enabled'
    disableLocalAuth: false
    networkAcls: {
      defaultAction: 'Allow'
      bypass: 'AzureServices'
    }
  }
  tags: tags
}

// GPT Model Deployment
resource gptModelDeployment 'Microsoft.CognitiveServices/accounts/deployments@2025-07-01-preview' = {
  name: gptModelName
  parent: openAI
  properties: {
    model: {
      format: 'OpenAI'
      name: gptModelName
      version: gptModelVersion
    }
  }
  sku: {
    name: 'GlobalStandard'
    capacity: gptCapacity
  }
}

// Storage account
module storageAccount 'br/public:avm/res/storage/storage-account:0.15.0' = if (useLogin == true) {
  name: 'storageAccount'
  params: {
    name: '${abbrs.storageStorageAccounts}${resourceToken}'
    kind: 'StorageV2'
    location: location
    tags: tags
    skuName: 'Standard_LRS'
    blobServices: {
      containers: [
        {
          name: 'token-store'
          publicAccess: 'None'
        }
      ]
    }
  }
}

// Container registry
module containerRegistry 'br/public:avm/res/container-registry/registry:0.6.0' = {
  name: 'registry'
  params: {
    name: '${abbrs.containerRegistryRegistries}${resourceToken}'
    location: location
    tags: tags
    acrAdminUserEnabled: true
    exportPolicyStatus: 'enabled'
    publicNetworkAccess: 'Enabled'
    roleAssignments: [
      {
        principalId: mcpTodoServerAppIdentity.outputs.principalId
        principalType: 'ServicePrincipal'
        // ACR Pull role
        roleDefinitionIdOrName: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7f951dda-4ed3-4680-a7ca-43fe172d538d')
      }
      {
        principalId: mcpTodoClientAppIdentity.outputs.principalId
        principalType: 'ServicePrincipal'
        // ACR Pull role
        roleDefinitionIdOrName: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7f951dda-4ed3-4680-a7ca-43fe172d538d')
      }
    ]
  }
}

// Container apps environment
module containerAppsEnvironment 'br/public:avm/res/app/managed-environment:0.8.1' = {
  name: 'container-apps-environment'
  params: {
    logAnalyticsWorkspaceResourceId: monitoring.outputs.logAnalyticsWorkspaceResourceId
    name: '${abbrs.appManagedEnvironments}${resourceToken}'
    location: location
    zoneRedundant: false
  }
}

module mcpTodoServerAppIdentity 'br/public:avm/res/managed-identity/user-assigned-identity:0.4.0' = {
  name: 'mcpTodoServerAppIdentity'
  params: {
    name: '${abbrs.managedIdentityUserAssignedIdentities}mcptodoserverapp-${resourceToken}'
    location: location
  }
}

module mcpTodoServerAppIdentityRoleAssignment './modules/role-assignment.bicep' = if (useLogin == true) {
  name: 'mcpTodoServerAppIdentityRoleAssignment'
  params: {
    managedIdentityName: mcpTodoServerAppIdentity.outputs.name
    storageAccountName: storageAccount.outputs.name
    principalType: 'ServicePrincipal'
  }
}

module mcpTodoServerAppFetchLatestImage './modules/fetch-container-image.bicep' = {
  name: 'mcptodo-serverapp-fetch-image'
  params: {
    exists: mcpTodoServerAppExists
    name: 'mcptodo-serverapp'
  }
}

module mcpTodoServerApp 'br/public:avm/res/app/container-app:0.16.0' = {
  name: 'mcpTodoServerApp'
  params: {
    name: 'mcptodo-serverapp'
    ingressTargetPort: mcpServerIngressPort
    ingressExternal: mcpServerIngressExternal
    scaleSettings: {
      minReplicas: 1
      maxReplicas: 10
    }
    secrets: [
      {
        name: 'jwt-audience'
        value: jwtAudience
      }
      {
        name: 'jwt-issuer'
        value: jwtIssuer
      }
      {
        name: 'jwt-expiry'
        value: jwtExpiry
      }
      {
        name: 'jwt-secret'
        value: jwtSecret
      }
      {
        name: 'jwt-token'
        value: jwtToken
      }
    ]
    containers: [
      {
        image: mcpTodoServerAppFetchLatestImage.outputs.?containers[?0].?image ?? 'mcr.microsoft.com/azuredocs/containerapps-helloworld:latest'
        name: 'main'
        resources: {
          cpu: json('0.5')
          memory: '1.0Gi'
        }
        env: concat([
          {
            name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
            value: monitoring.outputs.applicationInsightsConnectionString
          }
          {
            name: 'AZURE_CLIENT_ID'
            value: mcpTodoServerAppIdentity.outputs.clientId
          }
          {
            name: 'PORT'
            value: '${mcpServerIngressPort}'
          }
          {
            name: 'JWT_AUDIENCE'
            secretRef: 'jwt-audience'
          }
          {
            name: 'JWT_ISSUER'
            secretRef: 'jwt-issuer'
          }
          {
            name: 'JWT_EXPIRY'
            secretRef: 'jwt-expiry'
          }
          {
            name: 'JWT_SECRET'
            secretRef: 'jwt-secret'
          }
          {
            name: 'JWT_TOKEN'
            secretRef: 'jwt-token'
          }
        ], enableMcpServerDevelopmentMode == true ? [
          {
            name: 'NODE_ENV'
            value: 'development'
          }
        ] : [])
      }
    ]
    managedIdentities: {
      systemAssigned: false
      userAssignedResourceIds: [
        mcpTodoServerAppIdentity.outputs.resourceId
      ]
    }
    registries: [
      {
        server: containerRegistry.outputs.loginServer
        identity: mcpTodoServerAppIdentity.outputs.resourceId
      }
    ]
    environmentResourceId: containerAppsEnvironment.outputs.resourceId
    location: location
    tags: union(tags, { 'azd-service-name': 'mcptodo-serverapp' })
  }
}

module mcpTodoClientAppIdentity 'br/public:avm/res/managed-identity/user-assigned-identity:0.4.0' = {
  name: 'mcpTodoClientAppIdentity'
  params: {
    name: '${abbrs.managedIdentityUserAssignedIdentities}mcptodoclientapp-${resourceToken}'
    location: location
  }
}

module mcpTodoClientAppIdentityRoleAssignment './modules/role-assignment.bicep' = if (useLogin == true) {
  name: 'mcpTodoClientAppIdentityRoleAssignment'
  params: {
    managedIdentityName: mcpTodoClientAppIdentity.outputs.name
    storageAccountName: storageAccount.outputs.name
    principalType: 'ServicePrincipal'
  }
}

module mcpTodoClientAppFetchLatestImage './modules/fetch-container-image.bicep' = {
  name: 'mcptodo-clientapp-fetch-image'
  params: {
    exists: mcpTodoClientAppExists
    name: 'mcptodo-clientapp'
  }
}

module mcpTodoClientApp 'br/public:avm/res/app/container-app:0.16.0' = {
  name: 'mcpTodoClientApp'
  params: {
    name: 'mcptodo-clientapp'
    ingressTargetPort: mcpClientIngressPort
    ingressExternal: true
    scaleSettings: {
      minReplicas: 1
      maxReplicas: 10
    }
    secrets: [
      {
        name: 'openai-endpoint'
        value: openAI.properties.endpoint
      }
      {
        name: 'openai-api-key'
        value: openAI.listKeys().key1
      }
      {
        name: 'jwt-token'
        value: jwtToken
      }
    ]
    containers: [
      {
        image: mcpTodoClientAppFetchLatestImage.outputs.?containers[?0].?image ?? 'mcr.microsoft.com/azuredocs/containerapps-helloworld:latest'
        name: 'main'
        resources: {
          cpu: json('0.5')
          memory: '1.0Gi'
        }
        env: [
          {
            name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
            value: monitoring.outputs.applicationInsightsConnectionString
          }
          {
            name: 'AZURE_CLIENT_ID'
            value: mcpTodoClientAppIdentity.outputs.clientId
          }
          {
            name: 'PORT'
            value: '${mcpClientIngressPort}'
          }
          {
            name: 'McpServers__TodoList'
            value: 'https://${mcpTodoServerApp.outputs.fqdn}'
          }
          {
            name: 'OpenAI__Endpoint'
            secretRef: 'openai-endpoint'
          }
          {
            name: 'OpenAI__ApiKey'
            secretRef: 'openai-api-key'
          }
          {
            name: 'OpenAI__DeploymentName'
            value: gptModelDeployment.properties.model.name
          }
          {
            name: 'McpServers__JWT__Token'
            secretRef: 'jwt-token'
          }
        ]
      }
    ]
    managedIdentities: {
      systemAssigned: false
      userAssignedResourceIds: [
        mcpTodoClientAppIdentity.outputs.resourceId
      ]
    }
    registries: [
      {
        server: containerRegistry.outputs.loginServer
        identity: mcpTodoClientAppIdentity.outputs.resourceId
      }
    ]
    environmentResourceId: containerAppsEnvironment.outputs.resourceId
    location: location
    tags: union(tags, { 'azd-service-name': 'mcptodo-clientapp' })
  }
}

// EasyAuth
var issuer = '${environment().authentication.loginEndpoint}${tenant().tenantId}/v2.0'

module appRegistration './modules/app-registration.bicep' = if (useLogin == true) {
  name: 'appRegistration'
  params: {
    appName: 'spn-${environmentName}'
    issuer: issuer
    containerAppIdentityId: mcpTodoClientAppIdentity.outputs.principalId
    containerAppEndpoint: 'https://${mcpTodoClientApp.outputs.fqdn}'
  }
}

module mcpTodoClientAppAuthConfig './modules/containerapps-authconfigs.bicep' = if (useLogin == true) {
  name: 'mcpTodoClientAppAuthConfig'
  params: {
    containerAppName: mcpTodoClientApp.outputs.name
    managedIdentityName: mcpTodoClientAppIdentity.outputs.name
    storageAccountName: storageAccount.outputs.name
    clientId: appRegistration.outputs.appId
    openIdIssuer: issuer
    unauthenticatedClientAction: 'RedirectToLoginPage'
  }
}

output AZURE_PRINCIPAL_ID string = useLogin ? appRegistration.outputs.appId : ''

output AZURE_CONTAINER_REGISTRY_ENDPOINT string = containerRegistry.outputs.loginServer

output AZURE_RESOURCE_MCPTODO_SERVERAPP_ID string = mcpTodoServerApp.outputs.resourceId
output AZURE_RESOURCE_MCPTODO_SERVERAPP_NAME string = mcpTodoServerApp.outputs.name
output AZURE_RESOURCE_MCPTODO_SERVERAPP_URL string = 'https://${mcpTodoServerApp.outputs.fqdn}'

output AZURE_RESOURCE_MCPTODO_CLIENTAPP_ID string = mcpTodoClientApp.outputs.resourceId
output AZURE_RESOURCE_MCPTODO_CLIENTAPP_NAME string = mcpTodoClientApp.outputs.name
output AZURE_RESOURCE_MCPTODO_CLIENTAPP_URL string = 'https://${mcpTodoClientApp.outputs.fqdn}'
