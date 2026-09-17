Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ============================================================
# PATHS
# ============================================================

$scriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = Resolve-Path "$scriptDirectory\..\.."
$envFile = Join-Path $projectRoot ".env"

if (-not (Test-Path $envFile)) {
  throw ".env not found at '$envFile'"
}


# ============================================================
# ENV
# ============================================================

function Expand-DotEnvValue {
  param(
    [string] $Value,
    [hashtable] $Values
  )

  for ($i = 0; $i -lt 10; $i++) {
    $matches = [regex]::Matches(
      $Value,
      '\$\{([A-Za-z_][A-Za-z0-9_]*)\}'
    )

    if ($matches.Count -eq 0) {
      break
    }

    foreach ($match in $matches) {
      $variableName = $match.Groups[1].Value

      if ($Values.ContainsKey($variableName)) {
        $replacement = $Values[$variableName]
      }
      else {
        $replacement = [Environment]::GetEnvironmentVariable(
          $variableName
        )
      }

      if ([string]::IsNullOrEmpty($replacement)) {
        continue
      }

      $Value = $Value.Replace(
        $match.Value,
        $replacement
      )
    }
  }

  return $Value
}


function Import-DotEnv {
  param(
    [string] $Path
  )

  $values = @{}

  foreach ($rawLine in Get-Content $Path) {
    $line = $rawLine.Trim()

    if (
    [string]::IsNullOrWhiteSpace($line) -or
      $line.StartsWith("#")
    ) {
      continue
    }

    $separatorIndex = $line.IndexOf("=")

    if ($separatorIndex -le 0) {
      continue
    }

    $name = $line.Substring(
      0,
      $separatorIndex
    ).Trim()

    $value = $line.Substring(
      $separatorIndex + 1
    ).Trim()

    if (
    ($value.StartsWith('"') -and $value.EndsWith('"')) -or
      ($value.StartsWith("'") -and $value.EndsWith("'"))
    ) {
      $value = $value.Substring(
        1,
        $value.Length - 2
      )
    }

    $values[$name] = $value
  }

  # Resolve ${VARIABLE} references.
  for ($i = 0; $i -lt 10; $i++) {
    foreach ($name in @($values.Keys)) {
      $values[$name] = Expand-DotEnvValue `
                -Value $values[$name] `
                -Values $values
    }
  }

  foreach ($name in $values.Keys) {
    [Environment]::SetEnvironmentVariable(
      $name,
      $values[$name],
      "Process"
    )
  }
}


Import-DotEnv -Path $envFile


# ============================================================
# CONFIG
# ============================================================

$applicationName = $env:APPLICATION_NAME
$kcPort = $env:KC_PORT

$adminUsername = $env:KC_BOOTSTRAP_ADMIN_USERNAME
$adminPassword = $env:KC_BOOTSTRAP_ADMIN_PASSWORD

$backendClientId = $env:KC_SERVICE_CLIENT_ID
$backendClientSecret = $env:KC_SERVICE_CLIENT_SECRET
$apiClientId = $env:KC_API_CLIENT_ID
$appClientId = $env:KC_APP_CLIENT_ID

$appWebRedirectUri = $env:KC_APP_WEB_REDIRECT_URI
$appWebOrigin = $env:KC_APP_WEB_ORIGIN
$appMobileRedirectUri = $env:KC_APP_MOBILE_REDIRECT_URI

$kcBase = "http://localhost:$kcPort"
$realm = $applicationName


# ============================================================
# HTTP
# ============================================================

function Get-AdminToken {
  Write-Host "[KEYCLOAK] Authenticating admin..."

  $body = @{
    grant_type = "password"
    client_id  = "admin-cli"
    username   = $adminUsername
    password   = $adminPassword
  }

  $response = Invoke-RestMethod `
        -Method Post `
        -Uri "$kcBase/realms/master/protocol/openid-connect/token" `
        -ContentType "application/x-www-form-urlencoded" `
        -Body $body `
        -ErrorAction Stop

  return $response.access_token
}


$adminToken = Get-AdminToken

$headers = @{
  Authorization = "Bearer $adminToken"
}


function Invoke-Keycloak {
  param(
    [Parameter(Mandatory)]
    [string] $Method,

    [Parameter(Mandatory)]
    [string] $Path,

    [object] $Body = $null
  )

  $arguments = @{
    Method      = $Method
    Uri         = "$kcBase$Path"
    Headers     = $headers
    ErrorAction = "Stop"
  }

  if ($null -ne $Body) {
    $arguments["ContentType"] = "application/json"
    $arguments["Body"] = (
    $Body |
      ConvertTo-Json -Depth 20
    )
  }

  try {
    $response = Invoke-RestMethod @arguments

    if ($null -eq $response) {
      return
    }

    if ($response -is [System.Array]) {
      foreach ($item in $response) {
        Write-Output $item
      }

      return
    }

    return $response
  }
  catch {
    Write-Host ""
    Write-Host "[ERROR] Keycloak request failed"
    Write-Host "Method: $Method"
    Write-Host "Path:   $Path"

    if ($null -ne $Body) {
      Write-Host ""
      Write-Host "Request body:"
      Write-Host (
      $Body |
        ConvertTo-Json -Depth 20
      )
    }

    Write-Host ""

    throw
  }
}


# ============================================================
# CLIENTS
# ============================================================

function Get-KeycloakClient {
  param(
    [Parameter(Mandatory)]
    [string] $ClientId
  )

  $encodedClientId = [uri]::EscapeDataString(
    $ClientId
  )

  $clients = @(
    Invoke-Keycloak `
      -Method "GET" `
      -Path "/admin/realms/$realm/clients?clientId=$encodedClientId"
  )

  foreach ($client in $clients) {
    if ($client.clientId -eq $ClientId) {
      return $client
    }
  }

  return $null
}

function Ensure-Client {
  param(
    [Parameter(Mandatory)]
    [string] $ClientId,

    [Parameter(Mandatory)]
    [hashtable] $Representation
  )

  $client = Get-KeycloakClient `
        -ClientId $ClientId

  if ($null -eq $client) {
    Write-Host "[CREATE] Client '$ClientId'"

    Invoke-Keycloak `
            -Method "POST" `
            -Path "/admin/realms/$realm/clients" `
            -Body $Representation |
      Out-Null

    $client = Get-KeycloakClient `
            -ClientId $ClientId
  }
  else {
    Write-Host "[UPDATE] Client '$ClientId'"

    Invoke-Keycloak `
            -Method "PUT" `
            -Path "/admin/realms/$realm/clients/$($client.id)" `
            -Body $Representation |
      Out-Null

    $client = Get-KeycloakClient `
            -ClientId $ClientId
  }

  if ($null -eq $client) {
    throw "Unable to resolve Keycloak client '$ClientId'"
  }

  return $client
}


# ============================================================
# PROTOCOL MAPPERS
# ============================================================

function Ensure-ProtocolMapper {
  param(
    [Parameter(Mandatory)]
    [string] $ClientInternalId,

    [Parameter(Mandatory)]
    [string] $ClientId,

    [Parameter(Mandatory)]
    [string] $MapperName,

    [Parameter(Mandatory)]
    [hashtable] $Representation
  )

  $response = Invoke-Keycloak `
      -Method "GET" `
      -Path "/admin/realms/$realm/clients/$ClientInternalId/protocol-mappers/models"

  $existingMappers = @()

  foreach ($mapper in $response) {
    if ($mapper.name -eq $MapperName) {
      $existingMappers += $mapper
    }
  }

  if ($existingMappers.Count -gt 0) {
    Write-Host "[REPLACE] Mapper '$MapperName' on '$ClientId'"

    foreach ($existing in $existingMappers) {
      Write-Host "          DELETE $($existing.id)"

      Invoke-Keycloak `
          -Method "DELETE" `
          -Path "/admin/realms/$realm/clients/$ClientInternalId/protocol-mappers/models/$($existing.id)" |
        Out-Null
    }
  }
  else {
    Write-Host "[CREATE] Mapper '$MapperName' on '$ClientId'"
  }

  Invoke-Keycloak `
      -Method "POST" `
      -Path "/admin/realms/$realm/clients/$ClientInternalId/protocol-mappers/models" `
      -Body $Representation |
    Out-Null
}

# ============================================================
# REALM CHECK
# ============================================================

Write-Host "[KEYCLOAK] Checking realm '$realm'..."

$realmRepresentation = Invoke-Keycloak `
    -Method "GET" `
    -Path "/admin/realms/$realm"

Write-Host "[OK] Realm '$($realmRepresentation.realm)'"


# ============================================================
# WAYSTONE API
# ============================================================

$apiRepresentation = @{
  clientId                  = $apiClientId
  name                      = "Waystone API"
  description               = "Waystone REST API audience"
  enabled                   = $true

  protocol                  = "openid-connect"

  bearerOnly                = $true
  publicClient              = $false

  standardFlowEnabled       = $false
  implicitFlowEnabled       = $false
  directAccessGrantsEnabled = $false
  serviceAccountsEnabled    = $false
}

$apiClient = Ensure-Client `
    -ClientId $apiClientId `
    -Representation $apiRepresentation


# ============================================================
# WAYSTONE APP
# ============================================================

$appRepresentation = @{
  clientId                  = $appClientId
  name                      = "Waystone App"
  description               = "Public client for Waystone Web and Mobile"
  enabled                   = $true

  protocol                  = "openid-connect"

  publicClient              = $true
  bearerOnly                = $false

  standardFlowEnabled       = $true
  implicitFlowEnabled       = $false
  directAccessGrantsEnabled = $false
  serviceAccountsEnabled    = $false

  redirectUris = @(
    $appWebRedirectUri,
    $appMobileRedirectUri
  )

  webOrigins = @(
    $appWebOrigin
  )

  attributes = @{
    "pkce.code.challenge.method" = "S256"
  }
}

$appClient = Ensure-Client `
    -ClientId $appClientId `
    -Representation $appRepresentation


# ============================================================
# WAYSTONE BACKEND
# ============================================================

$backendClient = Get-KeycloakClient `
    -ClientId $backendClientId

if ($null -eq $backendClient) {
  throw "Required client '$backendClientId' does not exist"
}

Write-Host "[OK] Client '$backendClientId'"


# ============================================================
# AUDIENCE MAPPER
# ============================================================

$audienceMapper = @{
  name            = "waystone-api-audience"
  protocol        = "openid-connect"
  protocolMapper  = "oidc-audience-mapper"
  consentRequired = $false

  config = @{
    "included.client.audience"  = $apiClientId
    "included.custom.audience"  = ""
    "id.token.claim"            = "false"
    "access.token.claim"        = "true"
    "lightweight.claim"         = "false"
    "introspection.token.claim" = "true"
  }
}

Ensure-ProtocolMapper `
    -ClientInternalId $backendClient.id `
    -ClientId $backendClientId `
    -MapperName "waystone-api-audience" `
    -Representation $audienceMapper

Ensure-ProtocolMapper `
    -ClientInternalId $appClient.id `
    -ClientId $appClientId `
    -MapperName "waystone-api-audience" `
    -Representation $audienceMapper


# ============================================================
# GROUPS MAPPER
# ============================================================

$groupsMapper = @{
  name            = "waystone-groups"
  protocol        = "openid-connect"
  protocolMapper  = "oidc-group-membership-mapper"
  consentRequired = $false

  config = @{
    "claim.name"                = "groups"
    "full.path"                 = "true"
    "id.token.claim"            = "false"
    "access.token.claim"        = "true"
    "userinfo.token.claim"      = "false"
    "introspection.token.claim" = "true"
  }
}

Ensure-ProtocolMapper `
    -ClientInternalId $appClient.id `
    -ClientId $appClientId `
    -MapperName "waystone-groups" `
    -Representation $groupsMapper

# ============================================================
# VERIFICATION
# ============================================================

function Get-ProtocolMappers {
  param(
    [Parameter(Mandatory)]
    [string] $ClientInternalId
  )

  return @(
    Invoke-Keycloak `
      -Method "GET" `
      -Path "/admin/realms/$realm/clients/$ClientInternalId/protocol-mappers/models"
  )
}


function Assert-ProtocolMapper {
  param(
    [Parameter(Mandatory)]
    [string] $ClientInternalId,

    [Parameter(Mandatory)]
    [string] $ClientId,

    [Parameter(Mandatory)]
    [string] $MapperName
  )

  $mappers = Get-ProtocolMappers `
    -ClientInternalId $ClientInternalId

  $matches = @()

  foreach ($mapper in $mappers) {
    if ($mapper.name -eq $MapperName) {
      $matches += $mapper
    }
  }

  if ($matches.Count -ne 1) {
    throw "Expected exactly one mapper '$MapperName' on '$ClientId', found $($matches.Count)"
  }

  Write-Host "[VERIFY] Mapper '$MapperName' on '$ClientId' OK"
}


function Decode-JwtPayload {
  param(
    [Parameter(Mandatory)]
    [string] $Token
  )

  $parts = $Token.Split(".")

  if ($parts.Length -ne 3) {
    throw "Invalid JWT format"
  }

  $payload = $parts[1]
  $payload = $payload.Replace("-", "+").Replace("_", "/")

  switch ($payload.Length % 4) {
    2 {
      $payload += "=="
    }

    3 {
      $payload += "="
    }
  }

  $json = [Text.Encoding]::UTF8.GetString(
    [Convert]::FromBase64String($payload)
  )

  return $json | ConvertFrom-Json
}


Write-Host ""
Write-Host "[VERIFY] Checking Keycloak configuration..."

# ------------------------------------------------------------
# VERIFY BACKEND AUDIENCE MAPPER
# ------------------------------------------------------------

Assert-ProtocolMapper `
  -ClientInternalId $backendClient.id `
  -ClientId $backendClientId `
  -MapperName "waystone-api-audience"


# ------------------------------------------------------------
# VERIFY APP AUDIENCE MAPPER
# ------------------------------------------------------------

Assert-ProtocolMapper `
  -ClientInternalId $appClient.id `
  -ClientId $appClientId `
  -MapperName "waystone-api-audience"


# ------------------------------------------------------------
# VERIFY APP GROUPS MAPPER
# ------------------------------------------------------------

Assert-ProtocolMapper `
  -ClientInternalId $appClient.id `
  -ClientId $appClientId `
  -MapperName "waystone-groups"


# ------------------------------------------------------------
# VERIFY BACKEND ACCESS TOKEN AUDIENCE
# ------------------------------------------------------------

Write-Host "[VERIFY] Requesting service account token..."

$tokenBody = @{
  grant_type    = "client_credentials"
  client_id     = $backendClientId
  client_secret = $backendClientSecret
}

$tokenResponse = Invoke-RestMethod `
  -Method Post `
  -Uri "$kcBase/realms/$realm/protocol/openid-connect/token" `
  -ContentType "application/x-www-form-urlencoded" `
  -Body $tokenBody `
  -ErrorAction Stop

$accessToken = $tokenResponse.access_token

if ([string]::IsNullOrWhiteSpace($accessToken)) {
  throw "Keycloak did not return an access token for '$backendClientId'"
}

$jwtPayload = Decode-JwtPayload `
  -Token $accessToken

$audiences = @($jwtPayload.aud)

if ($audiences -notcontains $apiClientId) {
  throw "Token audience does not contain '$apiClientId'. Found: $($audiences -join ', ')"
}

Write-Host "[VERIFY] Token audience '$apiClientId' OK"

# ============================================================
# RESULT
# ============================================================

Write-Host ""
Write-Host "============================================="
Write-Host " Keycloak configuration completed"
Write-Host "============================================="
Write-Host ""
Write-Host "Realm:          $realm"
Write-Host "Backend client: $backendClientId"
Write-Host "API audience:   $apiClientId"
Write-Host "App client:     $appClientId"
Write-Host ""
