<#
    .SYNOPSIS
        Deploys a module to an Azure Automation account.

    .DESCRIPTION
        Deploys a PowerShell module to an Azure Automation account from a repository like the PowerShell Gallery.
        Supports credentials to access private repositories.
        Inspired by https://blog.tyang.org/2017/02/17/managing-azure-automation-module-assets-using-myget/

        Sample snippet for PSDeploy configuration:

        By AzureAutomationModule {
            FromSource "https://www.powershellgallery.com/api/v2"
            To "MyAutomationAccountName"
            WithOptions @{
                SourceIsAbsolute  = $true # Should be true if deploying from a gallery, and false if deploying from a local path
                ModuleName        = "PSDepend"
                ModuleVersion     = '0.3.0' # Optional. If not specified, the latest module version will be used.
                ResourceGroupName = "MyAutomationAccount_ResourceGroupName"
                Force             = $true # Optional. Use if you want to overwrite an already imported module with the same or lower module version.
        }
    }

    .PARAMETER Deployment
        Deployment to run

    .PARAMETER ModuleName
        Module to deploy

    .PARAMETER ModuleVersion
        Specific module version to use for deployment

    .PARAMETER PsGalleryApiUrl
        URL of PowerShell repository API

    .PARAMETER Credential
        Credential to use for accessing the PowerShell repository

    .PARAMETER Force
        Deploy the module even if the same module version is already imported into Azure Automation account

    .PARAMETER AutomationAccountName
        Azure Automation account to import the module

    .PARAMETER AutomationAccountResourceGroup
        The resource group of target Azure Automation account
#>

#Requires -modules Az.Automation
[CmdletBinding()]
param(
    [ValidateScript( { $_.PSObject.TypeNames[0] -eq 'PSDeploy.Deployment' })]
    [psobject[]]$Deployment,

    [Parameter(Mandatory = $true)]
    [string]$ModuleName,

    [Parameter(Mandatory = $false)]
    [string]$ModuleVersion,

    [Parameter(Mandatory = $false)]
    [pscredential]$Credential,

    [Parameter(Mandatory = $false)]
    [switch]$Force,

    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName
)

function Get-SourceModuleRepository {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $SourceLocation,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $ModuleName,

        [Parameter(Mandatory = $false)]
        [pscredential]$Credential
    )

    begin {
        Write-Verbose "Starting the configuration of target module repository to work with..."
    }

    process {
        Write-Verbose "Searching for a registered PowerShell repository with SourceLocation '$SourceLocation'..."

        $existingPSRepository = Get-PSRepository | Where-Object -Property SourceLocation -eq $SourceLocation

        if ($existingPSRepository) {
            Write-Verbose "An already registered repository '$($existingPSRepository.Name)' with the same SourceLocation has been found."

            # Setting target repository name
            $targetRepositoryName = $existingPSRepository.Name
        }
        else {
            Write-Verbose "No registered repository has been found. Registering a new PowerShell repository..."

            # Register-PSRepository parameters
            $params = @{
                Name           = $ModuleName + '-repository'
                SourceLocation = $SourceLocation
                Verbose        = $VerbosePreference
            }

            if ($Credential) {
                $params['Credential'] = $Credential
            }

            # Register a new repository
            Register-PSRepository @params

            # Setting target repository name
            $targetRepositoryName = $ModuleName + '-repository'
        }
    }

    end {
        Write-Verbose "The following PowerShell repository will be used as the target repository '$targetRepositoryName'."
        # Return the target repository
        Get-PSRepository -Name $targetRepositoryName | Write-Output
    }
}

function Get-SourceModule {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $ModuleName,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Repository,

        [Parameter(Mandatory = $false)]
        [string]
        $RequiredVersion,

        [Parameter(Mandatory = $false)]
        [pscredential]$Credential
    )

    begin {
        if ($ModuleVersion) {
            Write-Verbose "Searching for version '$RequiredVersion' of module '$ModuleName' in the repository '$Repository'..."
        }
        else {
            Write-Verbose "Searching for the latest version of module '$ModuleName' in the repository '$Repository'..."
        }
    }

    process {
        # Find-Module parameters
        $params = @{
            Name       = $ModuleName
            Repository = $Repository
            Verbose    = $VerbosePreference
        }

        if ($ModuleVersion) {
            $params['RequiredVersion'] = $RequiredVersion
        }

        if ($Credential) {
            $params['Credential'] = $Credential
        }

        # Look for the module
        $sourceModule = Find-Module @params

    }

    end {
        if ($sourceModule) {
            Write-Verbose "The version '$($sourceModule.Version)' of module '$($sourceModule.Name)' is found in the repository '$Repository'."
        }
        else {
            Write-Verbose "No target version of module '$ModuleName' is found in the repository '$Repository'."
        }

        # Return the target module
        Write-Output $sourceModule
    }
}

function Get-ModuleImportStatus {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true,
            ValueFromPipeline = $true,
            ValueFromPipelineByPropertyName = $true)]
        [ValidateNotNullOrEmpty()]
        $ModuleImportJob
    )

    begin {
        $importCompleted = $false
    }

    process {
        do {
            Write-Verbose 'Checking module import status...'
            $importedModule = Get-AzAutomationModule -Name $ModuleImportJob.Name -ResourceGroupName $ModuleImportJob.ResourceGroupName -AutomationAccountName $ModuleImportJob.AutomationAccountName
            if (($importedModule.ProvisioningState -eq 'Succeeded') -or ($importedModule.ProvisioningState -eq 'Failed')) {
                $importCompleted = $true
            }
            Start-Sleep -Seconds 5
        }
        until ($importCompleted -eq $true)
    }

    end {
        Write-Verbose "Module import status is: $($importedModule.ProvisioningState)"
        # Return the import job status
        # Write-Output $importedModule
    }
}

function Get-ImportedModule {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $ModuleName,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $AutomationAccountName,

        [Parameter(Mandatory = $false)]
        [string]
        $ResourceGroupName
    )

    begin {
        Write-Verbose "Searching for an existing module '$ModuleName' in the Automation account '$AutomationAccountName'..."
    }

    process {
        # Get-AzAutomationModule parameters
        $params = @{
            Name                  = $ModuleName
            AutomationAccountName = $AutomationAccountName
            ResourceGroupName     = $ResourceGroupName
            Verbose               = $VerbosePreference
        }

        $importedModule = Get-AzAutomationModule @params
    }

    end {
        if ($importedModule) {
            Write-Verbose "An existing module '$($importedModule.Name)' version '$($importedModule.Version)' was found in the Automation account '$($importedModule.AutomationAccountName)'."

            # Return the imported module
            Write-Output $importedModule
        }
        else {
            Write-Verbose "No existing module '$ModuleName' was found in the Automation account '$AutomationAccountName'."
        }
    }
}

function Import-SourceModule {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [psobject]
        $Module,
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [Microsoft.Azure.Commands.Automation.Model.AutomationAccount]
        $AutomationAccount
    )

    begin {

    }

    process {
        #region Searching for the source module in the Azure Automation account
        # Get-SourceModule parameters
        $params = @{
            ModuleName            = $Module.Name
            AutomationAccountName = $AutomationAccount.AutomationAccountName
            ResourceGroupName     = $AutomationAccount.ResourceGroupName
            Verbose               = $VerbosePreference
        }

        $targetModule = Get-ImportedModule @params
        #endregion

        # New-AzAutomationModule parameters
        $params = @{
            Name                  = $Module.Name
            AutomationAccountName = $AutomationAccount.AutomationAccountName
            ResourceGroupName     = $AutomationAccount.ResourceGroupName
            ContentLink           = $Module.RepositorySourceLocation + "/package/$($Module.Name)/$($Module.Version)/"
            Verbose               = $VerbosePreference
        }

        if ($targetModule) {
            if ($sourceModule.Version -gt ([version]::Parse($targetModule.Version))) {
                Write-Verbose "The source module version is '$($sourceModule.Version)', which is greater than the existing version in the Automation Account. Updating now..."
                $moduleImportJob = New-AzAutomationModule @params
            }
            elseif (($sourceModule.Version -le ([version]::Parse($targetModule.Version))) -and $Force) {
                Write-Warning "Forcing the target module import!"

                # Remove-AzAutomationModule parameters
                $removeParams = @{
                    Name                  = $targetModule.Name
                    AutomationAccountName = $target
                    ResourceGroupName     = $deploy.DeploymentOptions.ResourceGroupName
                    Force                 = $deploy.DeploymentOptions.Force
                    Verbose               = $VerbosePreference
                }

                Write-Warning "Removing the version '$($targetModule.Version)' of module '$($targetModule.Name)' from the the Automation Account '$target'..."
                Remove-AzAutomationModule @removeParams

                Write-Verbose "Importing the version '$($sourceModule.Version)' of module '$($sourceModule.Name)' into the Automation Account '$target'..."
                $moduleImportJob = New-AzAutomationModule @params
            }
            elseif ($sourceModule.Version -eq ([version]::Parse($targetModule.Version))) {
                Write-Verbose "The source module version is '$($sourceModule.Version)', which is the same as the existing version in the Automation Account. Update is not required."
            }
            else {
                Write-Verbose "The source module version is '$($sourceModule.Version)', which is lower than the existing version '$($targetModule.Version)' in the Automation Account. Update is not required."
            }
        }
        else {
            Write-Verbose "Importing the version '$($sourceModule.Version)' of module '$($sourceModule.Name)' into the Automation Account '$target'..."
            $moduleImportJob = New-AzAutomationModule @params
        }
    }

    end {
        Write-Output $moduleImportJob
    }
}

foreach ($deploy in $Deployment) {

    foreach ($target in $deploy.Targets) {
        Write-Verbose "Starting deployment '$($deploy.DeploymentName)' to Azure Automation account '$target' in '$ResourceGroupName' resource group."

        #region Setting up the module repository

        # Get-SourceModuleRepository parameters
        $params = @{
            ModuleName     = $deploy.DeploymentOptions.ModuleName
            SourceLocation = $deploy.Source
            Verbose        = $VerbosePreference
        }

        if ($Credential) {
            $params['Credential'] = $deploy.DeploymentOptions.Credential
        }

        $sourceModuleRepository = Get-SourceModuleRepository @params

        #region Searching for the target module in the repository
        if ($sourceModuleRepository) {

            # Get-SourceModule parameters
            $params = @{
                ModuleName = $deploy.DeploymentOptions.ModuleName
                Repository = $sourceModuleRepository.Name
                Verbose    = $VerbosePreference
            }

            if ($ModuleVersion) {
                $params['RequiredVersion'] = $ModuleVersion
            }

            if ($Credential) {
                $params['Credential'] = $Credential
            }

            $sourceModule = Get-SourceModule @params

            #region Importing the target module into an Azure Automation account
            if ($sourceModule) {

                $targetAzureAutomationAccount = Get-AzAutomationAccount -Name $target -ResourceGroupName $deploy.DeploymentOptions.ResourceGroupName

                if ($targetAzureAutomationAccount) {
                    # Import-SourceModule parameters
                    $params = @{
                        Module            = $sourceModule
                        AutomationAccount = $targetAzureAutomationAccount
                        Verbose           = $VerbosePreference
                    }

                    $moduleImportJob = Import-SourceModule @params

                    if ($moduleImportJob) {
                        $moduleImportJob | Get-ModuleImportStatus
                    }
                }
                else {
                    throw "The target Azure Automation account '$target' was not found in '$($deploy.DeploymentOptions.ResourceGroupName)' resource group."
                }
            }
            else {
                if ($ModuleVersion) {
                    throw "The version '$ModuleVersion' of source module '$($deploy.DeploymentOptions.ModuleName)' was not found in the repository '$($sourceModuleRepository.Name)'."
                }
                else {
                    throw "The source module '$($deploy.DeploymentOptions.ModuleName)' was not found in the repository '$($sourceModuleRepository.Name)'."
                }
            }
            #endregion

        }
        else {
            throw "Cannot register source module repository."
        }
        #endregion
    }
}

# TODO - Implement deployment from a private repository
# Need to create a storage account in the target Azure Automation account resource group
# Create a container, upload zipped module to the storage account and get its download link

function New-ContentLinkUri {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [Microsoft.Azure.Commands.Automation.Model.AutomationAccount]
        $AutomationAccount,
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Path
    )

    begin {
    }

    process {
        # New-AzStorageAccount parameters
        $params = @{
            Name              = $((Split-Path $Path -LeafBase) + 'stor')
            Location          = $AutomationAccount.Location
            ResourceGroupName = $AutomationAccount.ResourceGroupName
            SkuName           = "Standard_LRS"
            Verbose           = $VerbosePreference
        }

        # Create a storage account
        $storageAccount = New-AzStorageAccount @params

        $context = $storageAccount.Context

        # Create a container
        New-AzStorageContainer -Name $containerName -Context $context -Permission Container

        # Set-AzStorageBlobContent parameters
        $params = @{
            Container = $containerName
            File      = $Path
            Blob      = $(Split-Path $Path -Leaf)
            Context   = $context
            Verbose   = $VerbosePreference
        }

        # Upload the file
        Set-AzStorageBlobContent @params

        # Get secure context
        $key = (Get-AzStorageAccountKey -ResourceGroupName $storageAccount.ResourceGroupName -Name $storageAccount.StorageAccountName).Value[0]
        $context = New-AzStorageContext -StorageAccountName $storageAccount.StorageAccountName -StorageAccountKey $key

        # New-AzStorageBlobSASToken parameters
        $params = @{
            Context    = $context
            Container  = $containerName
            Blob       = $(Split-Path $Path -Leaf)
            Permission = 'r'
            ExpiryTime = (Get-Date).AddHours(2.0)
            FullUri    = $true
            Verbose    = $VerbosePreference
        }

        # Generate a SAS token
        $contentLinkUri = New-AzStorageBlobSASToken @params
    }

    end {
        Write-Output $contentLinkUri
    }
}

function New-ModuleZipFile {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, ParameterSetName = 'PSRepository')]
        [ValidateNotNullOrEmpty()]
        [psobject]
        $Module,
        [Parameter(Mandatory = $false, ParameterSetName = 'PSRepository')]
        [pscredential]$Credential,
        [Parameter(Mandatory = $true, ParameterSetName = 'Local source')]
        [ValidateNotNullOrEmpty()]
        [string]
        $Path
    )

    begin {

    }

    process {
        # Creating a zip file from the module in the source repository
        if ($Module) {

            # Save-Module parameters
            $params = @{
                InputObject = $Module
                Path        = $PSScriptRoot
                Force       = $true
                Verbose     = $VerbosePreference
            }

            if ($Credential) {
                $params['Credential'] = $Credential
            }

            $sourceModulePath = Save-Module @params
        }
        # Creating a zip file from the local source path
        elseif ($Path) {
            $sourceModulePath = $Path
        }

        $zipFile = Compress-Archive -Path $sourceModulePath -DestinationPath $("{0}.zip" -f (Get-Item -Path $sourceModulePath).FullName) -Force
    }

    end {
        Write-Output $zipFile
    }
}