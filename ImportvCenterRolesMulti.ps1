[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(
        Mandatory = $true,
        ParameterSetName = "ServerList"
    )]
    [string[]]$DestinationVC,

    [Parameter(
        Mandatory = $true,
        ParameterSetName = "ServerFile"
    )]
    [string]$DestinationVCFile,

    [Parameter(Mandatory = $false)]
    [string]$ImportFolder = "C:\Staging\vCenterRoles",

    [Parameter(Mandatory = $false)]
    [string[]]$RoleName,

    [Parameter(Mandatory = $false)]
    [PSCredential]$Credential,

    [Parameter(Mandatory = $false)]
    [switch]$UpdateExistingRoles
)

$ErrorActionPreference = "Stop"
$AllResults = @()
$ActiveConnections = @()

function Add-DeploymentResult {
    param(
        [string]$VCenter,
        [string]$Role,
        [string]$JsonFile,
        [int]$RequestedPrivileges,
        [int]$AvailablePrivileges,
        [int]$AppliedPrivileges,
        [string[]]$MissingPrivileges,
        [string]$Status,
        [string]$Message
    )

    $script:AllResults += [PSCustomObject]@{
        DestinationVCenter = $VCenter
        RoleName           = $Role
        JsonFile           = $JsonFile
        RequestedCount     = $RequestedPrivileges
        AvailableCount     = $AvailablePrivileges
        AppliedCount       = $AppliedPrivileges
        MissingCount       = @($MissingPrivileges).Count
        MissingPrivileges  = @($MissingPrivileges) -join ";"
        Status             = $Status
        Message            = $Message
        ProcessedAt        = Get-Date -Format "o"
    }
}

try {
    Write-Host ""
    Write-Host "Multi-vCenter custom role deployment" -ForegroundColor Cyan
    Write-Host "------------------------------------" -ForegroundColor Cyan
    Write-Host "Import folder : $ImportFolder"
    Write-Host ""

    if (-not (Test-Path -LiteralPath $ImportFolder -PathType Container)) {
        throw "The import folder does not exist: $ImportFolder"
    }

    $JsonFiles = @(
        Get-ChildItem `
            -LiteralPath $ImportFolder `
            -Filter "*.json" `
            -File `
            -ErrorAction Stop |
        Sort-Object -Property Name
    )

    if ($JsonFiles.Count -eq 0) {
        throw "No JSON role files were found in '$ImportFolder'."
    }

    #
    # Build the destination vCenter list.
    #
    if ($PSCmdlet.ParameterSetName -eq "ServerFile") {
        if (-not (Test-Path -LiteralPath $DestinationVCFile -PathType Leaf)) {
            throw "The destination vCenter file does not exist: $DestinationVCFile"
        }

        $FileExtension = [System.IO.Path]::GetExtension(
            $DestinationVCFile
        )

        if ($FileExtension -ieq ".csv") {
            $ImportedServers = @(
                Import-Csv `
                    -LiteralPath $DestinationVCFile `
                    -ErrorAction Stop
            )

            if (
                $ImportedServers.Count -gt 0 -and
                $ImportedServers[0].PSObject.Properties.Name -contains "vCenter"
            ) {
                $DestinationVC = @(
                    $ImportedServers |
                    Select-Object -ExpandProperty vCenter
                )
            }
            elseif (
                $ImportedServers.Count -gt 0 -and
                $ImportedServers[0].PSObject.Properties.Name -contains "Server"
            ) {
                $DestinationVC = @(
                    $ImportedServers |
                    Select-Object -ExpandProperty Server
                )
            }
            else {
                throw "The CSV must contain a column named 'vCenter' or 'Server'."
            }
        }
        else {
            $DestinationVC = @(
                Get-Content `
                    -LiteralPath $DestinationVCFile `
                    -ErrorAction Stop
            )
        }
    }

    $DestinationVC = @(
        $DestinationVC |
        Where-Object { $_ } |
        ForEach-Object { $_.ToString().Trim() } |
        Where-Object { $_ } |
        Sort-Object -Unique
    )

    if ($DestinationVC.Count -eq 0) {
        throw "No valid destination vCenter names were provided."
    }

    #
    # Load and validate the role definitions before connecting.
    #
    $RequestedRoleNames = @()

    if ($RoleName) {
        $RequestedRoleNames = @(
            $RoleName |
            Where-Object { $_ } |
            ForEach-Object { $_.ToString().Trim() } |
            Where-Object { $_ } |
            Sort-Object -Unique
        )
    }

    $RoleDefinitions = @()

    foreach ($JsonFile in $JsonFiles) {
        try {
            $JsonContent = Get-Content `
                -LiteralPath $JsonFile.FullName `
                -Raw `
                -ErrorAction Stop

            if (-not $JsonContent) {
                Write-Warning "Skipping empty JSON file: $($JsonFile.Name)"
                continue
            }

            $Definition = $JsonContent |
                ConvertFrom-Json `
                    -ErrorAction Stop

            if (-not $Definition.RoleName) {
                Write-Warning "Skipping JSON without RoleName: $($JsonFile.Name)"
                continue
            }

            $DefinitionRoleName = $Definition.RoleName.ToString().Trim()

            if (-not $DefinitionRoleName) {
                Write-Warning "Skipping JSON with an empty RoleName: $($JsonFile.Name)"
                continue
            }

            if (
                $RequestedRoleNames.Count -gt 0 -and
                $DefinitionRoleName -notin $RequestedRoleNames
            ) {
                continue
            }

            $PrivilegeIds = @(
                $Definition.PrivilegeIds |
                Where-Object { $_ } |
                ForEach-Object { $_.ToString().Trim() } |
                Where-Object { $_ } |
                Sort-Object -Unique
            )

            if ($PrivilegeIds.Count -eq 0) {
                Write-Warning "Skipping role with no privileges: $DefinitionRoleName"
                continue
            }

            $RoleDefinitions += [PSCustomObject]@{
                RoleName     = $DefinitionRoleName
                JsonFile     = $JsonFile.Name
                JsonPath     = $JsonFile.FullName
                PrivilegeIds = $PrivilegeIds
            }
        }
        catch {
            Write-Warning "Unable to read '$($JsonFile.Name)': $($_.Exception.Message)"
        }
    }

    if ($RoleDefinitions.Count -eq 0) {
        throw "No valid role definitions were found for deployment."
    }

    Write-Host "Destination vCenters : $($DestinationVC.Count)"
    Write-Host "Role definitions     : $($RoleDefinitions.Count)"
    Write-Host ""

    Write-Host "vCenters:" -ForegroundColor Cyan

    foreach ($ServerName in $DestinationVC) {
        Write-Host "  $ServerName"
    }

    Write-Host ""
    Write-Host "Roles:" -ForegroundColor Cyan

    foreach ($Definition in $RoleDefinitions) {
        Write-Host "  $($Definition.RoleName)"
    }

    Write-Host ""

    #
    # Ask for one credential and reuse it for all vCenters.
    #
    if ($null -eq $Credential) {
        $Credential = Get-Credential `
            -Message "Enter an SSO account with permission to manage roles on all destination vCenters"
    }

    #
    # Process every destination vCenter.
    #
    foreach ($ServerName in $DestinationVC) {
        $Connection = $null

        Write-Host ""
        Write-Host "==================================================" `
            -ForegroundColor Cyan
        Write-Host "Processing vCenter: $ServerName" `
            -ForegroundColor Cyan
        Write-Host "==================================================" `
            -ForegroundColor Cyan

        try {
            Write-Host "Connecting..." -ForegroundColor Cyan

            $Connection = Connect-VIServer `
                -Server $ServerName `
                -Credential $Credential `
                -NotDefault `
                -ErrorAction Stop

            $ActiveConnections += $Connection

            Write-Host "Connected to $($Connection.Name)." `
                -ForegroundColor Green

            #
            # Retrieve privileges once for this vCenter.
            #
            Write-Host "Retrieving privileges..." `
                -ForegroundColor Cyan

            $DestinationPrivileges = @(
                Get-VIPrivilege `
                    -Server $Connection `
                    -PrivilegeItem `
                    -ErrorAction Stop
            )

            $PrivilegeLookup = @{}

            foreach ($Privilege in $DestinationPrivileges) {
                if ($null -ne $Privilege.Id) {
                    $PrivilegeId = $Privilege.Id.ToString()

                    if ($PrivilegeId) {
                        $PrivilegeLookup[$PrivilegeId] = $Privilege
                    }
                }
            }

            #
            # Retrieve roles once for this vCenter.
            #
            Write-Host "Retrieving existing roles..." `
                -ForegroundColor Cyan

            $DestinationRoles = @(
                Get-VIRole `
                    -Server $Connection `
                    -ErrorAction Stop
            )

            $RoleLookup = @{}

            foreach ($DestinationRole in $DestinationRoles) {
                if ($null -ne $DestinationRole.Name) {
                    $DestinationRoleName = $DestinationRole.Name.ToString()

                    if ($DestinationRoleName) {
                        $RoleLookup[$DestinationRoleName] = $DestinationRole
                    }
                }
            }

            Write-Host "Available privileges : $($PrivilegeLookup.Count)"
            Write-Host "Existing roles       : $($RoleLookup.Count)"
            Write-Host ""

            #
            # Process every role on this vCenter.
            #
            foreach ($Definition in $RoleDefinitions) {
                $CurrentRoleName = $Definition.RoleName
                $RequestedIds = @($Definition.PrivilegeIds)
                $PrivilegesToApply = @()
                $MissingIds = @()

                Write-Host "Role: $CurrentRoleName" `
                    -ForegroundColor Yellow

                foreach ($PrivilegeId in $RequestedIds) {
                    if ($PrivilegeLookup.ContainsKey($PrivilegeId)) {
                        $PrivilegesToApply += $PrivilegeLookup[$PrivilegeId]
                    }
                    else {
                        $MissingIds += $PrivilegeId
                    }
                }

                Write-Host "  Requested : $($RequestedIds.Count)" `
                    -ForegroundColor DarkGray
                Write-Host "  Available : $($PrivilegesToApply.Count)" `
                    -ForegroundColor DarkGray
                Write-Host "  Missing   : $($MissingIds.Count)" `
                    -ForegroundColor DarkGray

                if ($MissingIds.Count -gt 0) {
                    Write-Host "  Privileges unavailable on this vCenter:" `
                        -ForegroundColor Yellow

                    foreach ($MissingId in $MissingIds) {
                        Write-Host "    $MissingId" `
                            -ForegroundColor DarkYellow
                    }
                }

                if ($PrivilegesToApply.Count -eq 0) {
                    Write-Host "  Failed: no requested privileges are available." `
                        -ForegroundColor Red

                    Add-DeploymentResult `
                        -VCenter $Connection.Name `
                        -Role $CurrentRoleName `
                        -JsonFile $Definition.JsonFile `
                        -RequestedPrivileges $RequestedIds.Count `
                        -AvailablePrivileges 0 `
                        -AppliedPrivileges 0 `
                        -MissingPrivileges $MissingIds `
                        -Status "Failed" `
                        -Message "No requested privileges exist on the destination"

                    Write-Host ""
                    continue
                }

                if ($RoleLookup.ContainsKey($CurrentRoleName)) {
                    $ExistingRole = $RoleLookup[$CurrentRoleName]

                    if (-not $UpdateExistingRoles) {
                        Write-Host "  Role already exists; skipped." `
                            -ForegroundColor Yellow

                        Add-DeploymentResult `
                            -VCenter $Connection.Name `
                            -Role $CurrentRoleName `
                            -JsonFile $Definition.JsonFile `
                            -RequestedPrivileges $RequestedIds.Count `
                            -AvailablePrivileges $PrivilegesToApply.Count `
                            -AppliedPrivileges 0 `
                            -MissingPrivileges $MissingIds `
                            -Status "Skipped" `
                            -Message "Role already exists; no changes made"

                        Write-Host ""
                        continue
                    }

                    $ExistingIds = @(
                        $ExistingRole.PrivilegeList |
                        Where-Object { $_ } |
                        ForEach-Object { $_.ToString().Trim() } |
                        Where-Object { $_ } |
                        Sort-Object -Unique
                    )

                    $PrivilegesToAdd = @(
                        $PrivilegesToApply |
                        Where-Object {
                            $_.Id.ToString() -notin $ExistingIds
                        }
                    )

                    if ($PrivilegesToAdd.Count -eq 0) {
                        Write-Host "  Existing role already contains all available privileges." `
                            -ForegroundColor Green

                        Add-DeploymentResult `
                            -VCenter $Connection.Name `
                            -Role $CurrentRoleName `
                            -JsonFile $Definition.JsonFile `
                            -RequestedPrivileges $RequestedIds.Count `
                            -AvailablePrivileges $PrivilegesToApply.Count `
                            -AppliedPrivileges 0 `
                            -MissingPrivileges $MissingIds `
                            -Status "Compliant" `
                            -Message "Existing role already contains all available privileges"

                        Write-Host ""
                        continue
                    }

                    if (
                        $PSCmdlet.ShouldProcess(
                            $Connection.Name,
                            "Add $($PrivilegesToAdd.Count) privileges to role '$CurrentRoleName'"
                        )
                    ) {
                        Set-VIRole `
                            -Role $ExistingRole `
                            -AddPrivilege $PrivilegesToAdd `
                            -Confirm:$false `
                            -ErrorAction Stop |
                            Out-Null

                        Write-Host "  Existing role updated." `
                            -ForegroundColor Green

                        Add-DeploymentResult `
                            -VCenter $Connection.Name `
                            -Role $CurrentRoleName `
                            -JsonFile $Definition.JsonFile `
                            -RequestedPrivileges $RequestedIds.Count `
                            -AvailablePrivileges $PrivilegesToApply.Count `
                            -AppliedPrivileges $PrivilegesToAdd.Count `
                            -MissingPrivileges $MissingIds `
                            -Status "Updated" `
                            -Message "Missing privileges added to existing role"
                    }
                    else {
                        Add-DeploymentResult `
                            -VCenter $Connection.Name `
                            -Role $CurrentRoleName `
                            -JsonFile $Definition.JsonFile `
                            -RequestedPrivileges $RequestedIds.Count `
                            -AvailablePrivileges $PrivilegesToApply.Count `
                            -AppliedPrivileges 0 `
                            -MissingPrivileges $MissingIds `
                            -Status "WhatIf" `
                            -Message "Existing role update simulated"
                    }
                }
                else {
                    if (
                        $PSCmdlet.ShouldProcess(
                            $Connection.Name,
                            "Create role '$CurrentRoleName' with $($PrivilegesToApply.Count) privileges"
                        )
                    ) {
                        $CreatedRole = New-VIRole `
                            -Name $CurrentRoleName `
                            -Privilege $PrivilegesToApply `
                            -Server $Connection `
                            -ErrorAction Stop

                        if ($null -eq $CreatedRole) {
                            throw "New-VIRole did not return a role object."
                        }

                        $RoleLookup[$CurrentRoleName] = $CreatedRole

                        Write-Host "  Role created successfully." `
                            -ForegroundColor Green

                        Add-DeploymentResult `
                            -VCenter $Connection.Name `
                            -Role $CurrentRoleName `
                            -JsonFile $Definition.JsonFile `
                            -RequestedPrivileges $RequestedIds.Count `
                            -AvailablePrivileges $PrivilegesToApply.Count `
                            -AppliedPrivileges $PrivilegesToApply.Count `
                            -MissingPrivileges $MissingIds `
                            -Status "Created" `
                            -Message "Role created successfully"
                    }
                    else {
                        Write-Host "  WhatIf: role was not created." `
                            -ForegroundColor Magenta

                        Add-DeploymentResult `
                            -VCenter $Connection.Name `
                            -Role $CurrentRoleName `
                            -JsonFile $Definition.JsonFile `
                            -RequestedPrivileges $RequestedIds.Count `
                            -AvailablePrivileges $PrivilegesToApply.Count `
                            -AppliedPrivileges 0 `
                            -MissingPrivileges $MissingIds `
                            -Status "WhatIf" `
                            -Message "Role creation simulated"
                    }
                }

                Write-Host ""
            }
        }
        catch {
            $ServerError = $_.Exception.Message

            Write-Host "vCenter processing failed: $ServerError" `
                -ForegroundColor Red

            Add-DeploymentResult `
                -VCenter $ServerName `
                -Role "" `
                -JsonFile "" `
                -RequestedPrivileges 0 `
                -AvailablePrivileges 0 `
                -AppliedPrivileges 0 `
                -MissingPrivileges @() `
                -Status "ConnectionFailed" `
                -Message $ServerError
        }
        finally {
            if ($null -ne $Connection) {
                Write-Host "Disconnecting from $($Connection.Name)..." `
                    -ForegroundColor Cyan

                Disconnect-VIServer `
                    -Server $Connection `
                    -Confirm:$false `
                    -ErrorAction SilentlyContinue

                $ActiveConnections = @(
                    $ActiveConnections |
                    Where-Object {
                        $_.Uid -ne $Connection.Uid
                    }
                )
            }
        }
    }

    #
    # Save consolidated results.
    #
    $Timestamp = Get-Date -Format "yyyyMMdd-HHmmss"

    $ResultsCsvPath = Join-Path `
        -Path $ImportFolder `
        -ChildPath "MultiVCenterRoleResults-$Timestamp.csv"

    $AllResults |
        Export-Csv `
            -LiteralPath $ResultsCsvPath `
            -NoTypeInformation `
            -Encoding UTF8 `
            -ErrorAction Stop

    $CreatedCount = @(
        $AllResults |
        Where-Object { $_.Status -eq "Created" }
    ).Count

    $UpdatedCount = @(
        $AllResults |
        Where-Object { $_.Status -eq "Updated" }
    ).Count

    $CompliantCount = @(
        $AllResults |
        Where-Object { $_.Status -eq "Compliant" }
    ).Count

    $SkippedCount = @(
        $AllResults |
        Where-Object { $_.Status -eq "Skipped" }
    ).Count

    $FailedCount = @(
        $AllResults |
        Where-Object {
            $_.Status -eq "Failed" -or
            $_.Status -eq "ConnectionFailed"
        }
    ).Count

    $WhatIfCount = @(
        $AllResults |
        Where-Object { $_.Status -eq "WhatIf" }
    ).Count

    Write-Host ""
    Write-Host "Multi-vCenter deployment completed." `
        -ForegroundColor Green
    Write-Host "---------------------------------" `
        -ForegroundColor Green
    Write-Host "vCenters requested : $($DestinationVC.Count)"
    Write-Host "Roles requested    : $($RoleDefinitions.Count)"
    Write-Host "Created            : $CreatedCount"
    Write-Host "Updated            : $UpdatedCount"
    Write-Host "Already compliant  : $CompliantCount"
    Write-Host "Skipped            : $SkippedCount"
    Write-Host "Failed             : $FailedCount"
    Write-Host "WhatIf             : $WhatIfCount"
    Write-Host "Results CSV         : $ResultsCsvPath"
    Write-Host ""

    $AllResults |
        Format-Table `
            DestinationVCenter,
            RoleName,
            Status,
            RequestedCount,
            AppliedCount,
            MissingCount `
            -AutoSize
}
catch {
    Write-Host ""
    Write-Host "Multi-vCenter deployment failed." `
        -ForegroundColor Red
    Write-Host $_.Exception.Message `
        -ForegroundColor Red

    throw
}
finally {
    foreach ($RemainingConnection in $ActiveConnections) {
        Disconnect-VIServer `
            -Server $RemainingConnection `
            -Confirm:$false `
            -ErrorAction SilentlyContinue
    }
}
