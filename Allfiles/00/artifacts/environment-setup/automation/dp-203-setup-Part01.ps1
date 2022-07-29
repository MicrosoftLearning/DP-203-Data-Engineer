# Import modules
Import-Module Az.CosmosDB
Import-Module "..\solliance-synapse-automation"

# Paths
$artifactsPath = "..\..\"
$noteBooksPath = "..\notebooks"
$templatesPath = "..\templates"
$datasetsPath = "..\datasets"
$dataflowsPath = "..\dataflows"
$pipelinesPath = "..\pipelines"
$sqlScriptsPath = "..\sql"

# User must sign in using az login
Write-Host "Sign into Azure using your credentials.."
az login

# Now sign in again for PowerShell resource management and select subscription
Write-Host "Now sign in again to allow this script to create resources..."
Connect-AzAccount

$subs = Get-AzSubscription | Select-Object
if($subs.GetType().IsArray -and $subs.length -gt 1){
        Write-Host "Multiple subscriptions detected - please select the one you want to use:"
        for($i = 0; $i -lt $subs.length; $i++)
        {
                Write-Host "[$($i)]: $($subs[$i].Name) (ID = $($subs[$i].Id))"
        }
        $selectedIndex = -1
        $selectedValidIndex = 0
        while ($selectedValidIndex -ne 1)
        {
                $enteredValue = Read-Host("Enter 0 to $($subs.Length - 1)")
                if (-not ([string]::IsNullOrEmpty($enteredValue)))
                {
                    if ([int]$enteredValue -in (0..$($subs.Length - 1)))
                    {
                        $selectedIndex = [int]$enteredValue
                        $selectedValidIndex = 1
                    }
                    else
                    {
                        Write-Output "Please enter a valid subscription number."
                    }
                }
                else
                {
                    Write-Output "Please enter a valid subscription number."
                }
        }
        $selectedSub = $subs[$selectedIndex].Id
        Select-AzSubscription -SubscriptionId $selectedSub
        az account set --subscription $selectedSub
}

$userName = ((az ad signed-in-user show) | ConvertFrom-JSON).UserPrincipalName
write-host "User Name: $userName"
$userId = az ad signed-in-user show --query id -o tsv
Write-Host "User ID: $userId"

# Prompt user for a password for the SQL Database
write-host ""
$sqlPassword = ""
$complexPassword = 0

while ($complexPassword -ne 1)
{
    $sqlPassword = Read-Host "Enter a password for the Azure SQL Database.
    `The password must meet complexity requirements:
    ` - Minimum 8 characters. 
    ` - At least one upper case English letter [A-Z
    ` - At least one lower case English letter [a-z]
    ` - At least one digit [0-9]
    ` - At least one special character (!,@,#,%,^,&,$)
    ` "

    if(($sqlPassword -cmatch '[a-z]') -and ($sqlPassword -cmatch '[A-Z]') -and ($sqlPassword -match '\d') -and ($sqlPassword.length -ge 8) -and ($sqlPassword -match '!|@|#|%|^|&|$'))
    {
        $complexPassword = 1
    }
    else
    {
        Write-Output "$sqlPassword does not meet the compexity requirements."
    }
}


# Register resource providers

Write-Host "Registering resource providers...";
Register-AzResourceProvider -ProviderNamespace Microsoft.Databricks
Register-AzResourceProvider -ProviderNamespace Microsoft.Synapse
Register-AzResourceProvider -ProviderNamespace Microsoft.Sql
Register-AzResourceProvider -ProviderNamespace Microsoft.DocumentDB
Register-AzResourceProvider -ProviderNamespace Microsoft.StreamAnalytics
Register-AzResourceProvider -ProviderNamespace Microsoft.EventHub
Register-AzResourceProvider -ProviderNamespace Microsoft.KeyVault
Register-AzResourceProvider -ProviderNamespace Microsoft.Storage
Register-AzResourceProvider -ProviderNamespace Microsoft.Compute

# Generate a random suffix for unique Azure resource names
[string]$suffix =  -join ((48..57) + (97..122) | Get-Random -Count 7 | % {[char]$_})
Write-Host "Your randomly-generated suffix for Azure resources is $suffix"
$resourceGroupName = "data-engineering-synapse-$suffix"

# Select a random location that supports the required resource providers
# (required to balance resource capacity across regions)
Write-Host "Selecting a region for deployment..."

$preferred_list = "australiaeast","northeurope", "southeastasia","uksouth","westeurope","westus","westus2"
$locations = Get-AzLocation | Where-Object {
    $_.Providers -contains "Microsoft.Synapse" -and
    $_.Providers -contains "Microsoft.Databricks" -and
    $_.Providers -contains "Microsoft.Sql" -and
    $_.Providers -contains "Microsoft.DocumentDB" -and
    $_.Providers -contains "Microsoft.StreamAnalytics" -and
    $_.Providers -contains "Microsoft.EventHub" -and
    $_.Providers -contains "Microsoft.KeyVault" -and
    $_.Providers -contains "Microsoft.Storage" -and
    $_.Providers -contains "Microsoft.Compute" -and
    $_.Location -in $preferred_list
}
$max_index = $locations.Count - 1
$rand = (0..$max_index) | Get-Random
$random_location = $locations.Get($rand).Location

Write-Host "Try to create a SQL Database resource to test for capacity constraints";
# Try to create a SQL Databasde resource to test for capacity constraints
$success = 0
$tried_list = New-Object Collections.Generic.List[string]
$testPassword = ConvertTo-SecureString $sqlPassword -AsPlainText -Force
$testCred = New-Object System.Management.Automation.PSCredential ("SQLUser", $testPassword)
$testServer = "testsql$suffix"
while ($success -ne 1){
    try {
        $success = 1
        New-AzResourceGroup -Name $resourceGroupName -Location $random_location | Out-Null
        New-AzSqlServer -ResourceGroupName $resourceGroupName -Location $random_location -ServerName $testServer -ServerVersion "12.0" -SqlAdministratorCredentials $testCred -ErrorAction Stop | Out-Null
    }
    catch {
      Remove-AzResourceGroup -Name $resourceGroupName -Force
      $success = 0
      $tried_list.Add($random_location)
      $locations = $locations | Where-Object {$_.Location -notin $tried_list}
      $rand = (0..$($locations.Count - 1)) | Get-Random
      $random_location = $locations.Get($rand).Location
    }
}
Remove-AzSqlServer -ResourceGroupName $resourceGroupName -ServerName $testServer | Out-Null

Write-Host "Selected region: $random_location"

# Use ARM template to deploy resources
Write-Host "Creating Azure resources. This may take some time..."

New-AzResourceGroupDeployment -ResourceGroupName $resourceGroupName `
  -TemplateFile "00-asa-workspace-core.json" `
  -Mode Complete `
  -uniqueSuffix $suffix `
  -sqlAdministratorLoginPassword $sqlPassword `
  -Force

# Post-deployment configuration begins here
Write-Host "Performing post-deployment configuration..."

# Variables
$uniqueId =  (Get-AzResourceGroup -Name $resourceGroupName).Tags["DeploymentId"]
$subscriptionId = (Get-AzContext).Subscription.Id
$tenantId = (Get-AzContext).Tenant.Id
$global:logindomain = (Get-AzContext).Tenant.Id;

$workspaceName = "asaworkspace$($suffix)"
$dataLakeAccountName = "asadatalake$($suffix)"
$blobStorageAccountName = "asastore$($suffix)"
$keyVaultName = "asakeyvault$($suffix)"
$keyVaultSQLUserSecretName = "SQL-USER-ASA"
$sqlPoolName = "SQLPool01"
$integrationRuntimeName = "AzureIntegrationRuntime01"
$sparkPoolName = "SparkPool01"
$global:sqlEndpoint = "$($workspaceName).sql.azuresynapse.net"
$global:sqlUser = "asa.sql.admin"

$global:synapseToken = ""
$global:synapseSQLToken = ""
$global:managementToken = ""
$global:powerbiToken = "";

$global:tokenTimes = [ordered]@{
        Synapse = (Get-Date -Year 1)
        SynapseSQL = (Get-Date -Year 1)
        Management = (Get-Date -Year 1)
        PowerBI = (Get-Date -Year 1)
}


# Add the current userto Admin roles
Write-Host "Granting $userName admin permissions..."
Assign-SynapseRole -WorkspaceName $workspaceName -RoleId "6e4bf58a-b8e1-4cc3-bbf9-d73143322b78" -PrincipalId $userId  # Workspace Admin
Assign-SynapseRole -WorkspaceName $workspaceName -RoleId "7af0c69a-a548-47d6-aea3-d00e69bd83aa" -PrincipalId $userId  # SQL Admin
Assign-SynapseRole -WorkspaceName $workspaceName -RoleId "c3a6d2f1-a26f-4810-9b0f-591308d5cbf1" -PrincipalId $userId  # Apache Spark Admin

#add the permission to the datalake to workspace
$id = (Get-AzADServicePrincipal -DisplayName $workspacename).id
New-AzRoleAssignment -Objectid $id -RoleDefinitionName "Storage Blob Data Owner" -Scope "/subscriptions/$subscriptionId/resourceGroups/$resourceGroupName/providers/Microsoft.Storage/storageAccounts/$dataLakeAccountName" -ErrorAction SilentlyContinue;
New-AzRoleAssignment -SignInName $userName -RoleDefinitionName "Storage Blob Data Owner" -Scope "/subscriptions/$subscriptionId/resourceGroups/$resourceGroupName/providers/Microsoft.Storage/storageAccounts/$dataLakeAccountName" -ErrorAction SilentlyContinue;

Write-Information "Setting Key Vault Access Policy"
Set-AzKeyVaultAccessPolicy -ResourceGroupName $resourceGroupName -VaultName $keyVaultName -UserPrincipalName $userName -PermissionsToSecrets set,delete,get,list
Set-AzKeyVaultAccessPolicy -ResourceGroupName $resourceGroupName -VaultName $keyVaultName -ObjectId $id -PermissionsToSecrets set,delete,get,list

#remove need to ask for the password in script.
Write-Host "Configuring services..."
$sqlPasswordSecret = Get-AzKeyVaultSecret -VaultName $keyVaultName -Name "SqlPassword"
$sqlPassword = '';
$ssPtr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($sqlPasswordSecret.SecretValue)
try {
    $sqlPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($ssPtr)
} finally {
    [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ssPtr)
}
$global:sqlPassword = $sqlPassword

Write-Information "Create SQL-USER-ASA Key Vault Secret"
$secretValue = ConvertTo-SecureString $sqlPassword -AsPlainText -Force
Set-AzKeyVaultSecret -VaultName $keyVaultName -Name $keyVaultSQLUserSecretName -SecretValue $secretValue

Write-Information "Create KeyVault linked service $($keyVaultName)"

$result = Create-KeyVaultLinkedService -TemplatesPath $templatesPath -WorkspaceName $workspaceName -Name $keyVaultName
Wait-ForOperation -WorkspaceName $workspaceName -OperationId $result.operationId

Write-Information "Create Integration Runtime $($integrationRuntimeName)"

$result = Create-IntegrationRuntime -TemplatesPath $templatesPath -SubscriptionId $subscriptionId -ResourceGroupName $resourceGroupName -WorkspaceName $workspaceName -Name $integrationRuntimeName -CoreCount 16 -TimeToLive 60
Wait-ForOperation -WorkspaceName $workspaceName -OperationId $result.operationId

Write-Information "Create Data Lake linked service $($dataLakeAccountName)"

$dataLakeAccountKey = List-StorageAccountKeys -SubscriptionId $subscriptionId -ResourceGroupName $resourceGroupName -Name $dataLakeAccountName
$result = Create-DataLakeLinkedService -TemplatesPath $templatesPath -WorkspaceName $workspaceName -Name $dataLakeAccountName  -Key $dataLakeAccountKey
Wait-ForOperation -WorkspaceName $workspaceName -OperationId $result.operationId

Write-Information "Create linked service for SQL pool $($sqlPoolName) with user asa.sql.admin"

$linkedServiceName = $sqlPoolName.ToLower()
$result = Create-SQLPoolKeyVaultLinkedService -TemplatesPath $templatesPath -WorkspaceName $workspaceName -Name $linkedServiceName -DatabaseName $sqlPoolName -UserName "asa.sql.admin" -KeyVaultLinkedServiceName $keyVaultName -SecretName $keyVaultSQLUserSecretName
Wait-ForOperation -WorkspaceName $workspaceName -OperationId $result.operationId

Write-Information "Create Blob Storage linked service $($blobStorageAccountName)"

$blobStorageAccountKey = List-StorageAccountKeys -SubscriptionId $subscriptionId -ResourceGroupName $resourceGroupName -Name $blobStorageAccountName
$result = Create-BlobStorageLinkedService -TemplatesPath $templatesPath -WorkspaceName $workspaceName -Name $blobStorageAccountName  -Key $blobStorageAccountKey
Wait-ForOperation -WorkspaceName $workspaceName -OperationId $result.operationId

$SetupStep2Variables = "
# Values from the first setup script here
`$selectedSub = `"$selectedSub`"
`$suffix = `"$suffix`"
`$subscriptionId = `"$subscriptionId`"
`$resourceGroupName = `"$resourceGroupName`"
`$workspaceName = `"$workspaceName`"
`$global:logindomain = `"$global:logindomain`"
`$global:sqlEndpoint = `"$global:sqlEndpoint`"
`$global:sqlUser = `"$global:sqlUser`"
`$global:synapseToken = `"`"
`$global:synapseSQLToken = `"`"
`$global:managementToken = `"`"
`$global:powerbiToken = `"`"
`$global:tokenTimes = [ordered]@{
        Synapse = (Get-Date -Year 1)
        SynapseSQL = (Get-Date -Year 1)
        Management = (Get-Date -Year 1)
        PowerBI = (Get-Date -Year 1)
}
"

((Get-Content -path .\dp-203-setup-Part02.ps1 -Raw) -replace '# Add Values from the first setup script here',"$SetupStep2Variables") | Set-Content -Path .\dp-203-setup-Part02.ps1

((Get-Content -path .\dp-203-setup-Part03.ps1 -Raw) -replace '# Add Values from the first setup script here',"$SetupStep2Variables") | Set-Content -Path .\dp-203-setup-Part03.ps1

$SetupStep2Variables


# Import modules
Import-Module Az.CosmosDB
Import-Module "..\solliance-synapse-automation"

# Paths
$artifactsPath = "..\..\"
$noteBooksPath = "..\notebooks"
$templatesPath = "..\templates"
$datasetsPath = "..\datasets"
$dataflowsPath = "..\dataflows"
$pipelinesPath = "..\pipelines"
$sqlScriptsPath = "..\sql"

# User must sign in using az login
Write-Host "Sign into Azure using your credentials.."
az login

# Now sign in again for PowerShell resource management and select subscription
Write-Host "Now sign in again to allow this script to create resources..."
Connect-AzAccount

$subs = Get-AzSubscription | Select-Object
if($subs.GetType().IsArray -and $subs.length -gt 1){
        Write-Host "Multiple subscriptions detected - please select the one you want to use:"
        for($i = 0; $i -lt $subs.length; $i++)
        {
                Write-Host "[$($i)]: $($subs[$i].Name) (ID = $($subs[$i].Id))"
        }
        $selectedIndex = -1
        $selectedValidIndex = 0
        while ($selectedValidIndex -ne 1)
        {
                $enteredValue = Read-Host("Enter 0 to $($subs.Length - 1)")
                if (-not ([string]::IsNullOrEmpty($enteredValue)))
                {
                    if ([int]$enteredValue -in (0..$($subs.Length - 1)))
                    {
                        $selectedIndex = [int]$enteredValue
                        $selectedValidIndex = 1
                    }
                    else
                    {
                        Write-Output "Please enter a valid subscription number."
                    }
                }
                else
                {
                    Write-Output "Please enter a valid subscription number."
                }
        }
        $selectedSub = $subs[$selectedIndex].Id
        Select-AzSubscription -SubscriptionId $selectedSub
        az account set --subscription $selectedSub
}

$userName = ((az ad signed-in-user show) | ConvertFrom-JSON).UserPrincipalName
write-host "User Name: $userName"
$userId = az ad signed-in-user show --query objectId -o tsv
Write-Host "User ID: $userId"

# Prompt user for a password for the SQL Database
write-host ""
$sqlPassword = ""
$complexPassword = 0

while ($complexPassword -ne 1)
{
    $sqlPassword = Read-Host "Enter a password for the Azure SQL Database.
    `The password must meet complexity requirements:
    ` - Minimum 8 characters. 
    ` - At least one upper case English letter [A-Z
    ` - At least one lower case English letter [a-z]
    ` - At least one digit [0-9]
    ` - At least one special character (!,@,#,%,^,&,$)
    ` "

    if(($sqlPassword -cmatch '[a-z]') -and ($sqlPassword -cmatch '[A-Z]') -and ($sqlPassword -match '\d') -and ($sqlPassword.length -ge 8) -and ($sqlPassword -match '!|@|#|%|^|&|$'))
    {
        $complexPassword = 1
    }
    else
    {
        Write-Output "$sqlPassword does not meet the compexity requirements."
    }
}


# Register resource providers

Write-Host "Registering resource providers...";
Register-AzResourceProvider -ProviderNamespace Microsoft.Databricks
Register-AzResourceProvider -ProviderNamespace Microsoft.Synapse
Register-AzResourceProvider -ProviderNamespace Microsoft.Sql
Register-AzResourceProvider -ProviderNamespace Microsoft.DocumentDB
Register-AzResourceProvider -ProviderNamespace Microsoft.StreamAnalytics
Register-AzResourceProvider -ProviderNamespace Microsoft.EventHub
Register-AzResourceProvider -ProviderNamespace Microsoft.KeyVault
Register-AzResourceProvider -ProviderNamespace Microsoft.Storage
Register-AzResourceProvider -ProviderNamespace Microsoft.Compute

# Generate a random suffix for unique Azure resource names
[string]$suffix =  -join ((48..57) + (97..122) | Get-Random -Count 7 | % {[char]$_})
Write-Host "Your randomly-generated suffix for Azure resources is $suffix"
$resourceGroupName = "data-engineering-synapse-$suffix"

# Select a random location that supports the required resource providers
# (required to balance resource capacity across regions)
Write-Host "Selecting a region for deployment..."

$preferred_list = "australiaeast","northeurope", "southeastasia","uksouth","westeurope","westus","westus2"
$locations = Get-AzLocation | Where-Object {
    $_.Providers -contains "Microsoft.Synapse" -and
    $_.Providers -contains "Microsoft.Databricks" -and
    $_.Providers -contains "Microsoft.Sql" -and
    $_.Providers -contains "Microsoft.DocumentDB" -and
    $_.Providers -contains "Microsoft.StreamAnalytics" -and
    $_.Providers -contains "Microsoft.EventHub" -and
    $_.Providers -contains "Microsoft.KeyVault" -and
    $_.Providers -contains "Microsoft.Storage" -and
    $_.Providers -contains "Microsoft.Compute" -and
    $_.Location -in $preferred_list
}
$max_index = $locations.Count - 1
$rand = (0..$max_index) | Get-Random
$random_location = $locations.Get($rand).Location

Write-Host "Try to create a SQL Database resource to test for capacity constraints";
# Try to create a SQL Databasde resource to test for capacity constraints
$success = 0
$tried_list = New-Object Collections.Generic.List[string]
$testPassword = ConvertTo-SecureString $sqlPassword -AsPlainText -Force
$testCred = New-Object System.Management.Automation.PSCredential ("SQLUser", $testPassword)
$testServer = "testsql$suffix"
while ($success -ne 1){
    try {
        $success = 1
        New-AzResourceGroup -Name $resourceGroupName -Location $random_location | Out-Null
        New-AzSqlServer -ResourceGroupName $resourceGroupName -Location $random_location -ServerName $testServer -ServerVersion "12.0" -SqlAdministratorCredentials $testCred -ErrorAction Stop | Out-Null
    }
    catch {
      Remove-AzResourceGroup -Name $resourceGroupName -Force
      $success = 0
      $tried_list.Add($random_location)
      $locations = $locations | Where-Object {$_.Location -notin $tried_list}
      $rand = (0..$($locations.Count - 1)) | Get-Random
      $random_location = $locations.Get($rand).Location
    }
}
Remove-AzSqlServer -ResourceGroupName $resourceGroupName -ServerName $testServer | Out-Null

Write-Host "Selected region: $random_location"

# Use ARM template to deploy resources
Write-Host "Creating Azure resources. This may take some time..."

New-AzResourceGroupDeployment -ResourceGroupName $resourceGroupName `
  -TemplateFile "00-asa-workspace-core.json" `
  -Mode Complete `
  -uniqueSuffix $suffix `
  -sqlAdministratorLoginPassword $sqlPassword `
  -Force

# Post-deployment configuration begins here
Write-Host "Performing post-deployment configuration..."

# Variables
$uniqueId =  (Get-AzResourceGroup -Name $resourceGroupName).Tags["DeploymentId"]
$subscriptionId = (Get-AzContext).Subscription.Id
$tenantId = (Get-AzContext).Tenant.Id
$global:logindomain = (Get-AzContext).Tenant.Id;

$workspaceName = "asaworkspace$($suffix)"
$dataLakeAccountName = "asadatalake$($suffix)"
$blobStorageAccountName = "asastore$($suffix)"
$keyVaultName = "asakeyvault$($suffix)"
$keyVaultSQLUserSecretName = "SQL-USER-ASA"
$sqlPoolName = "SQLPool01"
$integrationRuntimeName = "AzureIntegrationRuntime01"
$sparkPoolName = "SparkPool01"
$global:sqlEndpoint = "$($workspaceName).sql.azuresynapse.net"
$global:sqlUser = "asa.sql.admin"

$global:synapseToken = ""
$global:synapseSQLToken = ""
$global:managementToken = ""
$global:powerbiToken = "";

$global:tokenTimes = [ordered]@{
        Synapse = (Get-Date -Year 1)
        SynapseSQL = (Get-Date -Year 1)
        Management = (Get-Date -Year 1)
        PowerBI = (Get-Date -Year 1)
}


# Add the current userto Admin roles
Write-Host "Granting $userName admin permissions..."
Assign-SynapseRole -WorkspaceName $workspaceName -RoleId "6e4bf58a-b8e1-4cc3-bbf9-d73143322b78" -PrincipalId $userId  # Workspace Admin
Assign-SynapseRole -WorkspaceName $workspaceName -RoleId "7af0c69a-a548-47d6-aea3-d00e69bd83aa" -PrincipalId $userId  # SQL Admin
Assign-SynapseRole -WorkspaceName $workspaceName -RoleId "c3a6d2f1-a26f-4810-9b0f-591308d5cbf1" -PrincipalId $userId  # Apache Spark Admin

#add the permission to the datalake to workspace
$id = (Get-AzADServicePrincipal -DisplayName $workspacename).id
New-AzRoleAssignment -Objectid $id -RoleDefinitionName "Storage Blob Data Owner" -Scope "/subscriptions/$subscriptionId/resourceGroups/$resourceGroupName/providers/Microsoft.Storage/storageAccounts/$dataLakeAccountName" -ErrorAction SilentlyContinue;
New-AzRoleAssignment -SignInName $userName -RoleDefinitionName "Storage Blob Data Owner" -Scope "/subscriptions/$subscriptionId/resourceGroups/$resourceGroupName/providers/Microsoft.Storage/storageAccounts/$dataLakeAccountName" -ErrorAction SilentlyContinue;

Write-Information "Setting Key Vault Access Policy"
Set-AzKeyVaultAccessPolicy -ResourceGroupName $resourceGroupName -VaultName $keyVaultName -UserPrincipalName $userName -PermissionsToSecrets set,delete,get,list
Set-AzKeyVaultAccessPolicy -ResourceGroupName $resourceGroupName -VaultName $keyVaultName -ObjectId $id -PermissionsToSecrets set,delete,get,list

#remove need to ask for the password in script.
Write-Host "Configuring services..."
$sqlPasswordSecret = Get-AzKeyVaultSecret -VaultName $keyVaultName -Name "SqlPassword"
$sqlPassword = '';
$ssPtr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($sqlPasswordSecret.SecretValue)
try {
    $sqlPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($ssPtr)
} finally {
    [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ssPtr)
}
$global:sqlPassword = $sqlPassword

Write-Information "Create SQL-USER-ASA Key Vault Secret"
$secretValue = ConvertTo-SecureString $sqlPassword -AsPlainText -Force
Set-AzKeyVaultSecret -VaultName $keyVaultName -Name $keyVaultSQLUserSecretName -SecretValue $secretValue

Write-Information "Create KeyVault linked service $($keyVaultName)"

$result = Create-KeyVaultLinkedService -TemplatesPath $templatesPath -WorkspaceName $workspaceName -Name $keyVaultName
Wait-ForOperation -WorkspaceName $workspaceName -OperationId $result.operationId

Write-Information "Create Integration Runtime $($integrationRuntimeName)"

$result = Create-IntegrationRuntime -TemplatesPath $templatesPath -SubscriptionId $subscriptionId -ResourceGroupName $resourceGroupName -WorkspaceName $workspaceName -Name $integrationRuntimeName -CoreCount 16 -TimeToLive 60
Wait-ForOperation -WorkspaceName $workspaceName -OperationId $result.operationId

Write-Information "Create Data Lake linked service $($dataLakeAccountName)"

$dataLakeAccountKey = List-StorageAccountKeys -SubscriptionId $subscriptionId -ResourceGroupName $resourceGroupName -Name $dataLakeAccountName
$result = Create-DataLakeLinkedService -TemplatesPath $templatesPath -WorkspaceName $workspaceName -Name $dataLakeAccountName  -Key $dataLakeAccountKey
Wait-ForOperation -WorkspaceName $workspaceName -OperationId $result.operationId

Write-Information "Create linked service for SQL pool $($sqlPoolName) with user asa.sql.admin"

$linkedServiceName = $sqlPoolName.ToLower()
$result = Create-SQLPoolKeyVaultLinkedService -TemplatesPath $templatesPath -WorkspaceName $workspaceName -Name $linkedServiceName -DatabaseName $sqlPoolName -UserName "asa.sql.admin" -KeyVaultLinkedServiceName $keyVaultName -SecretName $keyVaultSQLUserSecretName
Wait-ForOperation -WorkspaceName $workspaceName -OperationId $result.operationId

Write-Information "Create Blob Storage linked service $($blobStorageAccountName)"

$blobStorageAccountKey = List-StorageAccountKeys -SubscriptionId $subscriptionId -ResourceGroupName $resourceGroupName -Name $blobStorageAccountName
$result = Create-BlobStorageLinkedService -TemplatesPath $templatesPath -WorkspaceName $workspaceName -Name $blobStorageAccountName  -Key $blobStorageAccountKey
Wait-ForOperation -WorkspaceName $workspaceName -OperationId $result.operationId

$SetupStep2Variables = "
# Values from the first setup script here
`$selectedSub = `"$selectedSub`"
`$suffix = `"$suffix`"
`$subscriptionId = `"$subscriptionId`"
`$resourceGroupName = `"$resourceGroupName`"
`$workspaceName = `"$workspaceName`"
`$global:logindomain = `"$global:logindomain`"
`$global:sqlEndpoint = `"$global:sqlEndpoint`"
`$global:sqlUser = `"$global:sqlUser`"
`$global:synapseToken = `"`"
`$global:synapseSQLToken = `"`"
`$global:managementToken = `"`"
`$global:powerbiToken = `"`"
`$global:tokenTimes = [ordered]@{
        Synapse = (Get-Date -Year 1)
        SynapseSQL = (Get-Date -Year 1)
        Management = (Get-Date -Year 1)
        PowerBI = (Get-Date -Year 1)
}
"

((Get-Content -path .\dp-203-setup-Part02.ps1 -Raw) -replace '# Add Values from the first setup script here',"$SetupStep2Variables") | Set-Content -Path .\dp-203-setup-Part02.ps1

((Get-Content -path .\dp-203-setup-Part03.ps1 -Raw) -replace '# Add Values from the first setup script here',"$SetupStep2Variables") | Set-Content -Path .\dp-203-setup-Part03.ps1

$SetupStep2Variables