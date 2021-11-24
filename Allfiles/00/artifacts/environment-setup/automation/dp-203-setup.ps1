# Import modules
Import-Module Az.CosmosDB
Import-Module "..\solliance-synapse-automation"

# To Invoke-RestMethod and Invoke-WebRequest works
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls -bor [Net.SecurityProtocolType]::Tls11 -bor [Net.SecurityProtocolType]::Tls12

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
    ` - At least one upper case English letter [A-Z]
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

$preferred_list = "australiaeast","centralus","eastus2","northeurope", "southcentralus", "southeastasia","uksouth","westeurope","westus","westus2"
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
  -administratorLoginPassword $sqlPassword `
  -Force


# Post-deployment configuration begins here
Write-Host "Performing post-deployment configuration..."

# Variables
$uniqueId =  (Get-AzResourceGroup -Name $resourceGroupName).Tags["DeploymentId"]
$subscriptionId = (Get-AzContext).Subscription.Id
$tenantId = (Get-AzContext).Tenant.Id
$global:logindomain = (Get-AzContext).Tenant.Id;

$workspaceName = "asaworkspace$($suffix)"
$cosmosDbAccountName = "asacosmosdb$($suffix)"
$cosmosDbDatabase = "CustomerProfile"
$cosmosDbContainer = "OnlineUserProfile01"
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

Write-Information "Create linked service for SQL pool $($sqlPoolName) with user asaexp.sql.admin"

$linkedServiceName = $sqlPoolName.ToLower()
$result = Create-SQLPoolKeyVaultLinkedService -TemplatesPath $templatesPath -WorkspaceName $workspaceName -Name $linkedServiceName -DatabaseName $sqlPoolName -UserName "asaexp.sql.admin" -KeyVaultLinkedServiceName $keyVaultName -SecretName $keyVaultSQLUserSecretName
Wait-ForOperation -WorkspaceName $workspaceName -OperationId $result.operationId

Write-Information "Create Blob Storage linked service $($blobStorageAccountName)"

$blobStorageAccountKey = List-StorageAccountKeys -SubscriptionId $subscriptionId -ResourceGroupName $resourceGroupName -Name $blobStorageAccountName
$result = Create-BlobStorageLinkedService -TemplatesPath $templatesPath -WorkspaceName $workspaceName -Name $blobStorageAccountName  -Key $blobStorageAccountKey
Wait-ForOperation -WorkspaceName $workspaceName -OperationId $result.operationId

Write-Information "Copy Data"
Write-Host "Uploading data to Azure..."

Ensure-ValidTokens $true

if ([System.Environment]::OSVersion.Platform -eq "Unix")
{
        $azCopyLink = Check-HttpRedirect "https://aka.ms/downloadazcopy-v10-linux"

        if (!$azCopyLink)
        {
                $azCopyLink = "https://azcopyvnext.azureedge.net/release20200709/azcopy_linux_amd64_10.5.0.tar.gz"
        }

        Invoke-WebRequest $azCopyLink -OutFile "azCopy.tar.gz"
        tar -xf "azCopy.tar.gz"
        $azCopyCommand = (Get-ChildItem -Path ".\" -Recurse azcopy).Directory.FullName
        cd $azCopyCommand
        chmod +x azcopy
        cd ..
        $azCopyCommand += "\azcopy"
}
else
{
        $azCopyLink = Check-HttpRedirect "https://aka.ms/downloadazcopy-v10-windows"

        if (!$azCopyLink)
        {
                $azCopyLink = "https://azcopyvnext.azureedge.net/release20200501/azcopy_windows_amd64_10.4.3.zip"
        }

        Invoke-WebRequest $azCopyLink -OutFile "azCopy.zip"
        Expand-Archive "azCopy.zip" -DestinationPath ".\" -Force
        $azCopyCommand = (Get-ChildItem -Path ".\" -Recurse azcopy.exe).Directory.FullName
        $azCopyCommand += "\azcopy"
}

#$jobs = $(azcopy jobs list)

$download = $true;

$dataLakeStorageUrl = "https://"+ $dataLakeAccountName + ".dfs.core.windows.net/"
$dataLakeStorageBlobUrl = "https://"+ $dataLakeAccountName + ".blob.core.windows.net/"
$dataLakeStorageAccountKey = (Get-AzStorageAccountKey -ResourceGroupName $resourceGroupName -AccountName $dataLakeAccountName)[0].Value
$dataLakeContext = New-AzStorageContext -StorageAccountName $dataLakeAccountName -StorageAccountKey $dataLakeStorageAccountKey

$destinationSasKey = New-AzStorageContainerSASToken -Container "wwi-02" -Context $dataLakeContext -Permission rwdl

if ($download)
{
        Write-Information "Copying wwi-02 directory to the data lake..."
        $wwi02 = Resolve-Path "../../../../wwi-02"

        $dataDirectories = @{
                salesmall = "wwi-02,/sale-small/"
                analytics = "wwi-02,/campaign-analytics/"
                security = "wwi-02,/security/"
                salespoc = "wwi-02,/sale-poc/"
                datagenerators = "wwi-02,/data-generators/"
                profiles1 = "wwi-02,/online-user-profiles-01/"
                profiles2 = "wwi-02,/online-user-profiles-02/"
                customerinfo = "wwi-02,/customer-info/"
        }

        foreach ($dataDirectory in $dataDirectories.Keys) {

                $vals = $dataDirectories[$dataDirectory].tostring().split(",");

                $source = $wwi02.Path + $vals[1];

                $path = $vals[0];

                $destination = $dataLakeStorageBlobUrl + $path + $destinationSasKey
                Write-Information "Copying directory $($source) to $($destination)"
                & $azCopyCommand copy $source $destination --recursive=true
        }
}

Refresh-Tokens


Write-Information "Create SQL scripts"
Write-Host "Creating SQL scripts..."

$sqlScripts = [ordered]@{
        "Column Level Security" = "Column Level Security"
        "Dynamic Data Masking" = "Dynamic Data Masking"
        "Row Level Security" = "Row Level Security"
        "Data Warehouse Optimization" = "Data Warehouse Optimization"
}

foreach ($sqlScriptName in $sqlScripts.Keys) {
        
        $sqlScriptFileName = "$sqlScriptName.sql"
        Write-Information "Creating SQL script $($sqlScriptName) from $($sqlScriptFileName)"
        
        $result = Create-SQLScript -TemplatesPath $templatesPath -WorkspaceName $workspaceName -Name $sqlScriptName -ScriptFileName $sqlScriptFileName
        $result = Wait-ForOperation -WorkspaceName $workspaceName -OperationId $result.operationId
        $result
}

Refresh-Tokens

#
# =============== COSMOS DB IMPORT - MUST REMAIN LAST IN SCRIPT !!! ====================
#            

Write-Host "Loading Cosmos DB..."             

$download = $true;

#generate new one just in case...
$destinationSasKey = New-AzStorageContainerSASToken -Container "wwi-02" -Context $dataLakeContext -Permission rwdl

Write-Information "Counting Cosmos DB item in database $($cosmosDbDatabase), container $($cosmosDbContainer)"
$documentCount = Count-CosmosDbDocuments -SubscriptionId $subscriptionId -ResourceGroupName $resourceGroupName -CosmosDbAccountName $cosmosDbAccountName `
                -CosmosDbDatabase $cosmosDbDatabase -CosmosDbContainer $cosmosDbContainer

Write-Information "Found $documentCount in Cosmos DB container $($cosmosDbContainer)"

#Install-Module -Name Az.CosmosDB

if ($documentCount -ne 100000) 
{
        # Increase RUs in CosmosDB container
        Write-Information "Increase Cosmos DB container $($cosmosDbContainer) to 10000 RUs"

        $container = Get-AzCosmosDBSqlContainer `
                -ResourceGroupName $resourceGroupName `
                -AccountName $cosmosDbAccountName -DatabaseName $cosmosDbDatabase `
                -Name $cosmosDbContainer

        Update-AzCosmosDBSqlContainer -ResourceGroupName $resourceGroupName `
                -AccountName $cosmosDbAccountName -DatabaseName $cosmosDbDatabase `
                -Name $cosmosDbContainer -Throughput 10000 `
                -PartitionKeyKind $container.Resource.PartitionKey.Kind `
                -PartitionKeyPath $container.Resource.PartitionKey.Paths

        $name = "wwi02_online_user_profiles_01_adal"
        Write-Information "Create dataset $($name)"
        $result = Create-Dataset -DatasetsPath $datasetsPath -WorkspaceName $workspaceName -Name $name -LinkedServiceName $dataLakeAccountName
        Wait-ForOperation -WorkspaceName $workspaceName -OperationId $result.operationId

        Write-Information "Create Cosmos DB linked service $($cosmosDbAccountName)"
        $cosmosDbAccountKey = List-CosmosDBKeys -SubscriptionId $subscriptionId -ResourceGroupName $resourceGroupName -Name $cosmosDbAccountName
        $result = Create-CosmosDBLinkedService -TemplatesPath $templatesPath -WorkspaceName $workspaceName -Name $cosmosDbAccountName -Database $cosmosDbDatabase -Key $cosmosDbAccountKey
        Wait-ForOperation -WorkspaceName $workspaceName -OperationId $result.operationId

        $name = "customer_profile_cosmosdb"
        Write-Information "Create dataset $($name)"
        $result = Create-Dataset -DatasetsPath $datasetsPath -WorkspaceName $workspaceName -Name $name -LinkedServiceName $cosmosDbAccountName
        Wait-ForOperation -WorkspaceName $workspaceName -OperationId $result.operationId

        $name = "Setup - Import User Profile Data into Cosmos DB"
        $fileName = "import_customer_profiles_into_cosmosdb"
        Write-Information "Create pipeline $($name)"
        Write-Host "Running pipeline..."
        $result = Create-Pipeline -PipelinesPath $pipelinesPath -WorkspaceName $workspaceName -Name $name -FileName $fileName
        Wait-ForOperation -WorkspaceName $workspaceName -OperationId $result.operationId

        Write-Information "Running pipeline $($name)"
        $pipelineRunResult = Run-Pipeline -WorkspaceName $workspaceName -Name $name
        $result = Wait-ForPipelineRun -WorkspaceName $workspaceName -RunId $pipelineRunResult.runId
        $result

        #
        # =============== WAIT HERE FOR PIPELINE TO FINISH - MIGHT TAKE ~45 MINUTES ====================
        #                         
        #                    COPY 100000 records to CosmosDB ==> SELECT VALUE COUNT(1) FROM C
        #

        $name = "Setup - Import User Profile Data into Cosmos DB"
        Write-Information "Delete pipeline $($name)"
        $result = Delete-ASAObject -WorkspaceName $workspaceName -Category "pipelines" -Name $name
        Wait-ForOperation -WorkspaceName $workspaceName -OperationId $result.operationId

        $name = "customer_profile_cosmosdb"
        Write-Information "Delete dataset $($name)"
        $result = Delete-ASAObject -WorkspaceName $workspaceName -Category "datasets" -Name $name
        Wait-ForOperation -WorkspaceName $workspaceName -OperationId $result.operationId

        $name = "wwi02_online_user_profiles_01_adal"
        Write-Information "Delete dataset $($name)"
        $result = Delete-ASAObject -WorkspaceName $workspaceName -Category "datasets" -Name $name
        Wait-ForOperation -WorkspaceName $workspaceName -OperationId $result.operationId

        $name = $cosmosDbAccountName
        Write-Information "Delete linked service $($name)"
        $result = Delete-ASAObject -WorkspaceName $workspaceName -Category "linkedServices" -Name $name
        Wait-ForOperation -WorkspaceName $workspaceName -OperationId $result.operationId
}

$container = Get-AzCosmosDBSqlContainer `
        -ResourceGroupName $resourceGroupName `
        -AccountName $cosmosDbAccountName -DatabaseName $cosmosDbDatabase `
        -Name $cosmosDbContainer

Update-AzCosmosDBSqlContainer -ResourceGroupName $resourceGroupName `
        -AccountName $cosmosDbAccountName -DatabaseName $cosmosDbDatabase `
        -Name $cosmosDbContainer -Throughput 400 `
        -PartitionKeyKind $container.Resource.PartitionKey.Kind `
        -PartitionKeyPath $container.Resource.PartitionKey.Paths

Write-Host "Setup complete!"
