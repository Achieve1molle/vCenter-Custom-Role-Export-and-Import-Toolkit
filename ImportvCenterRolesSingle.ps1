[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)]
    [string]$DestinationVC,

    [Parameter(Mandatory = $false)]
    [string]$ImportFolder = "C:\Staging\vCenterRoles",

    [Parameter(Mandatory = $false)]
    [string[]]$RoleName
)

$ErrorActionPreference = "Stop"
$Connection = $null
$ImportResults = @()

try {
    Write-Host ""
    Write-Host "vCenter custom role import" -ForegroundColor Cyan
    Write-Host "--------------------------" -ForegroundColor Cyan
    Write-Host "Destination vCenter : $DestinationVC"
    Write-Host "Import folder       : $ImportFolder"
    Write-Host ""

    if (-not (Test-Path -LiteralPath $ImportFolder -PathType Container)) {
        throw "The import folder does not exist: $ImportFolder"
    }

    $JsonFiles = @(
        Get-ChildItem -LiteralPath $ImportFolder -Filter "*.json" -File |
        Sort-Object -Property Name
    )

    if ($JsonFiles.Count -eq 0) {
        throw "No JSON files were found in '$ImportFolder'."
    }

    Write-Host "JSON files found: $($JsonFiles.Count)" -ForegroundColor Cyan
    Write-Host "Connecting to destination vCenter..." -ForegroundColor Cyan

    $Connection = Connect-VIServer `
        -Server $DestinationVC `
        -ErrorAction Stop

    Write-Host "Connected to $($Connection.Name)." -ForegroundColor Green
    Write-Host ""

    Write-Host "Retrieving available destination privileges..." `
        -ForegroundColor Cyan

    $AllDestinationPrivileges = @(
        Get-VIPrivilege `
            -Server $Connection `
            -PrivilegeItem `
            -ErrorAction Stop
    )

    $PrivilegeLookup = @{}

    foreach ($Privilege in $AllDestinationPrivileges) {
        if ($null -ne $Privilege.Id -and $Privilege.Id.ToString().Length -gt 0) {
            $PrivilegeLookup[$Privilege.Id.ToString()] = $Privilege
        }
    }

    Write-Host "Destination privileges found: $($PrivilegeLookup.Count)" `
        -ForegroundColor Green
    Write-Host ""

    $ExistingRoles = @(
        Get-VIRole `
            -Server $Connection `
            -ErrorAction Stop
    )

    $ExistingRoleLookup = @{}

    foreach ($ExistingRole in $ExistingRoles) {
        if ($null -ne $ExistingRole.Name) {
            $ExistingRoleLookup[$ExistingRole.Name.ToString()] = $ExistingRole
        }
    }

    $RequestedRoleNames = @()

    if ($RoleName) {
        $RequestedRoleNames = @(
            $RoleName |
            Where-Object { $_ } |
            ForEach-Object { $_.ToString().Trim() } |
            Where-Object { $_ }
        )
    }

    foreach ($JsonFile in $JsonFiles) {
        $CurrentRoleName = $JsonFile.BaseName
        $RequestedPrivilegeIds = @()
        $PrivilegesToImport = @()
        $MissingPrivilegeIds = @()

        Write-Host "Processing: $($JsonFile.Name)" -ForegroundColor Yellow

        try {
            $JsonContent = Get-Content `
                -LiteralPath $JsonFile.FullName `
                -Raw `
                -ErrorAction Stop

            if (-not $JsonContent) {
                throw "The JSON file is empty."
            }

            $Definition = $JsonContent |
                ConvertFrom-Json `
                    -ErrorAction Stop

            if (-not $Definition.RoleName) {
                throw "The JSON file does not contain a RoleName value."
            }

            $CurrentRoleName = $Definition.RoleName.ToString().Trim()

            if (-not $CurrentRoleName) {
                throw "The JSON file contains an empty RoleName value."
            }

            if (
                $RequestedRoleNames.Count -gt 0 -and
                $CurrentRoleName -notin $RequestedRoleNames
            ) {
                Write-Host "  Skipped by role-name filter." `
                    -ForegroundColor DarkGray

                continue
            }

            $RequestedPrivilegeIds = @(
                $Definition.PrivilegeIds |
                Where-Object { $_ } |
                ForEach-Object { $_.ToString().Trim() } |
                Where-Object { $_ } |
                Sort-Object -Unique
            )

            if ($RequestedPrivilegeIds.Count -eq 0) {
                throw "No privilege IDs were found in the JSON definition."
            }

            Write-Host "  Role name            : $CurrentRoleName" `
                -ForegroundColor DarkGray
            Write-Host "  Requested privileges : $($RequestedPrivilegeIds.Count)" `
                -ForegroundColor DarkGray

            if ($ExistingRoleLookup.ContainsKey($CurrentRoleName)) {
                Write-Host "  Role already exists; no changes made." `
                    -ForegroundColor Yellow

                $ImportResults += [PSCustomObject]@{
                    RoleName                = $CurrentRoleName
                    JsonFile                = $JsonFile.Name
                    DestinationVCenter      = $Connection.Name
                    RequestedPrivileges     = $RequestedPrivilegeIds.Count
                    AvailablePrivileges     = 0
                    MissingPrivileges       = 0
                    MissingPrivilegeIds     = ""
                    Status                  = "Skipped"
                    Message                 = "Role already exists"
                    ProcessedAt             = Get-Date -Format "o"
                }

                Write-Host ""
                continue
            }

            foreach ($PrivilegeId in $RequestedPrivilegeIds) {
                if ($PrivilegeLookup.ContainsKey($PrivilegeId)) {
                    $PrivilegesToImport += $PrivilegeLookup[$PrivilegeId]
                }
                else {
                    $MissingPrivilegeIds += $PrivilegeId
                }
            }

            Write-Host "  Available privileges : $($PrivilegesToImport.Count)" `
                -ForegroundColor DarkGray
            Write-Host "  Missing privileges   : $($MissingPrivilegeIds.Count)" `
                -ForegroundColor DarkGray

            if ($MissingPrivilegeIds.Count -gt 0) {
                Write-Host "  Privileges not available on the destination:" `
                    -ForegroundColor Yellow

                foreach ($MissingPrivilegeId in $MissingPrivilegeIds) {
                    Write-Host "    $MissingPrivilegeId" `
                        -ForegroundColor DarkYellow
                }
            }

            if ($PrivilegesToImport.Count -eq 0) {
                throw "None of the exported privileges exist on the destination vCenter."
            }

            $ShouldCreate = $PSCmdlet.ShouldProcess(
                $Connection.Name,
                "Create role '$CurrentRoleName' with $($PrivilegesToImport.Count) privileges"
            )

            if ($ShouldCreate) {
                $NewRole = New-VIRole `
                    -Name $CurrentRoleName `
                    -Privilege $PrivilegesToImport `
                    -Server $Connection `
                    -ErrorAction Stop

                if ($null -eq $NewRole) {
                    throw "New-VIRole did not return the newly created role."
                }

                $VerifiedRole = Get-VIRole `
                    -Name $CurrentRoleName `
                    -Server $Connection `
                    -ErrorAction Stop

                $VerifiedPrivilegeIds = @(
                    $VerifiedRole.PrivilegeList |
                    Where-Object { $_ } |
                    ForEach-Object { $_.ToString().Trim() } |
                    Where-Object { $_ } |
                    Sort-Object -Unique
                )

                $ExistingRoleLookup[$CurrentRoleName] = $VerifiedRole

                Write-Host "  Role created successfully." `
                    -ForegroundColor Green

                $ResultStatus = "Created"
                $ResultMessage = "Role created and verified"
                $ImportedPrivilegeCount = $VerifiedPrivilegeIds.Count
            }
            else {
                Write-Host "  WhatIf: Role was not created." `
                    -ForegroundColor Magenta

                $ResultStatus = "WhatIf"
                $ResultMessage = "Role creation simulated; no changes made"
                $ImportedPrivilegeCount = 0
            }

            $ImportResults += [PSCustomObject]@{
                RoleName                = $CurrentRoleName
                JsonFile                = $JsonFile.Name
                DestinationVCenter      = $Connection.Name
                RequestedPrivileges     = $RequestedPrivilegeIds.Count
                AvailablePrivileges     = $PrivilegesToImport.Count
                ImportedPrivileges      = $ImportedPrivilegeCount
                MissingPrivileges       = $MissingPrivilegeIds.Count
                MissingPrivilegeIds     = $MissingPrivilegeIds -join ";"
                Status                  = $ResultStatus
                Message                 = $ResultMessage
                ProcessedAt             = Get-Date -Format "o"
            }
        }
        catch {
            Write-Host "  Import failed: $($_.Exception.Message)" `
                -ForegroundColor Red

            $ImportResults += [PSCustomObject]@{
                RoleName                = $CurrentRoleName
                JsonFile                = $JsonFile.Name
                DestinationVCenter      = $Connection.Name
                RequestedPrivileges     = $RequestedPrivilegeIds.Count
                AvailablePrivileges     = $PrivilegesToImport.Count
                ImportedPrivileges      = 0
                MissingPrivileges       = $MissingPrivilegeIds.Count
                MissingPrivilegeIds     = $MissingPrivilegeIds -join ";"
                Status                  = "Failed"
                Message                 = $_.Exception.Message
                ProcessedAt             = Get-Date -Format "o"
            }
        }

        Write-Host ""
    }

    $ResultsCsvPath = Join-Path `
        -Path $ImportFolder `
        -ChildPath "RoleImportResults.csv"

    $ImportResults |
        Export-Csv `
            -LiteralPath $ResultsCsvPath `
            -NoTypeInformation `
            -Encoding UTF8 `
            -ErrorAction Stop

    $CreatedCount = @(
        $ImportResults |
        Where-Object { $_.Status -eq "Created" }
    ).Count

    $SkippedCount = @(
        $ImportResults |
        Where-Object { $_.Status -eq "Skipped" }
    ).Count

    $FailedCount = @(
        $ImportResults |
        Where-Object { $_.Status -eq "Failed" }
    ).Count

    $WhatIfCount = @(
        $ImportResults |
        Where-Object { $_.Status -eq "WhatIf" }
    ).Count

    Write-Host ""
    Write-Host "Import processing completed." -ForegroundColor Green
    Write-Host "----------------------------" -ForegroundColor Green
    Write-Host "Destination vCenter : $($Connection.Name)"
    Write-Host "Created             : $CreatedCount"
    Write-Host "Skipped             : $SkippedCount"
    Write-Host "Failed              : $FailedCount"
    Write-Host "WhatIf               : $WhatIfCount"
    Write-Host "Results CSV          : $ResultsCsvPath"
    Write-Host ""

    $ImportResults |
        Format-Table `
            RoleName,
            Status,
            RequestedPrivileges,
            ImportedPrivileges,
            MissingPrivileges `
            -AutoSize
}
catch {
    Write-Host ""
    Write-Host "Role import process failed." -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red

    throw
}
finally {
    if ($null -ne $Connection) {
        Write-Host ""
        Write-Host "Disconnecting from $($Connection.Name)..." `
            -ForegroundColor Cyan

        Disconnect-VIServer `
            -Server $Connection `
            -Confirm:$false `
            -ErrorAction SilentlyContinue
    }
}