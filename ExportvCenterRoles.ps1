[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SourceVC,

    [Parameter(Mandatory = $false)]
    [string]$ExportFolder = "C:\Staging\vCenterRoles",

    [Parameter(Mandatory = $false)]
    [string[]]$RoleName
)

$ErrorActionPreference = "Stop"
$Connection = $null

function ConvertTo-SafeFileName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $SafeName = $Name.Trim()

    foreach ($InvalidCharacter in [System.IO.Path]::GetInvalidFileNameChars()) {
        $SafeName = $SafeName.Replace(
            $InvalidCharacter.ToString(),
            "_"
        )
    }

    # Windows filenames cannot end with a space or period.
    $SafeName = $SafeName.Trim().TrimEnd(".")

    if (-not $SafeName) {
        $SafeName = "UnnamedRole"
    }

    return $SafeName
}

try {
    Write-Host ""
    Write-Host "vCenter custom role export" -ForegroundColor Cyan
    Write-Host "--------------------------" -ForegroundColor Cyan
    Write-Host "Source vCenter : $SourceVC"
    Write-Host "Export folder  : $ExportFolder"
    Write-Host ""

    if (-not (Test-Path -LiteralPath $ExportFolder)) {
        Write-Host "Creating export folder..." -ForegroundColor Cyan

        New-Item `
            -Path $ExportFolder `
            -ItemType Directory `
            -Force |
            Out-Null
    }

    Write-Host "Connecting to source vCenter..." -ForegroundColor Cyan

    $Connection = Connect-VIServer `
        -Server $SourceVC `
        -ErrorAction Stop

    Write-Host "Connected to $($Connection.Name)." -ForegroundColor Green
    Write-Host "Retrieving roles..." -ForegroundColor Cyan

    $AllRoles = @(
        Get-VIRole `
            -Server $Connection `
            -ErrorAction Stop |
        Sort-Object -Property Name
    )

    # PowerCLI versions can expose the system-role flag differently.
    # Check both the direct IsSystem property and the underlying SDK object.
    $CustomRoles = @(
        foreach ($CurrentRole in $AllRoles) {
            $IsSystemRole = $false

            if (
                $CurrentRole.PSObject.Properties.Name -contains "IsSystem"
            ) {
                $IsSystemRole = [bool]$CurrentRole.IsSystem
            }
            elseif (
                $null -ne $CurrentRole.ExtensionData -and
                $null -ne $CurrentRole.ExtensionData.Info
            ) {
                $IsSystemRole = [bool]$CurrentRole.ExtensionData.Info.System
            }

            if (-not $IsSystemRole) {
                $CurrentRole
            }
        }
    )

    if ($RoleName) {
        $RequestedRoleNames = @(
            $RoleName |
            Where-Object { $_ } |
            ForEach-Object { $_.Trim() }
        )

        $RolesToExport = @(
            $CustomRoles |
            Where-Object {
                $_.Name -in $RequestedRoleNames
            }
        )

        $FoundRoleNames = @(
            $RolesToExport |
            Select-Object -ExpandProperty Name
        )

        $MissingRoleNames = @(
            $RequestedRoleNames |
            Where-Object {
                $_ -notin $FoundRoleNames
            }
        )

        if ($MissingRoleNames.Count -gt 0) {
            Write-Warning "The following requested roles were not found or are system roles:"

            foreach ($MissingRoleName in $MissingRoleNames) {
                Write-Warning "  $MissingRoleName"
            }
        }
    }
    else {
        $RolesToExport = @($CustomRoles)
    }

    if ($RolesToExport.Count -eq 0) {
        throw "No matching custom roles were found on '$SourceVC'."
    }

    Write-Host ""
    Write-Host "Custom roles selected: $($RolesToExport.Count)" `
        -ForegroundColor Cyan
    Write-Host ""

    $RoleInventory = [System.Collections.Generic.List[object]]::new()
    $UsedFileNames = @{}

    foreach ($CurrentRole in $RolesToExport) {
        Write-Host "Exporting role: $($CurrentRole.Name)" `
            -ForegroundColor Yellow

        $PrivilegeIds = @(
            $CurrentRole.PrivilegeList |
            Where-Object { $_ } |
            ForEach-Object { $_.ToString().Trim() } |
            Where-Object { $_ } |
            Sort-Object -Unique
        )

        $SafeRoleName = ConvertTo-SafeFileName `
            -Name $CurrentRole.Name

        $JsonFileName = "$SafeRoleName.json"
        $DuplicateNumber = 1

        # Prevent collisions when separate role names produce the same
        # sanitized Windows filename.
        while (
            $UsedFileNames.ContainsKey(
                $JsonFileName.ToLowerInvariant()
            )
        ) {
            $DuplicateNumber++
            $JsonFileName = "$SafeRoleName-$DuplicateNumber.json"
        }

        $UsedFileNames[
            $JsonFileName.ToLowerInvariant()
        ] = $true

        $JsonPath = Join-Path `
            -Path $ExportFolder `
            -ChildPath $JsonFileName

        $ExportDate = Get-Date -Format "o"

        $RoleDefinition = [PSCustomObject]@{
            SchemaVersion  = 1
            SourceVCenter  = $Connection.Name
            RoleName       = $CurrentRole.Name
            PrivilegeCount = $PrivilegeIds.Count
            PrivilegeIds   = $PrivilegeIds
            ExportedAt     = $ExportDate
        }

        $RoleDefinition |
            ConvertTo-Json -Depth 10 |
            Set-Content `
                -LiteralPath $JsonPath `
                -Encoding UTF8 `
                -ErrorAction Stop

        if (-not (Test-Path -LiteralPath $JsonPath)) {
            throw "The JSON file was not created: $JsonPath"
        }

        $CreatedFile = Get-Item `
            -LiteralPath $JsonPath `
            -ErrorAction Stop

        $RoleInventory.Add(
            [PSCustomObject]@{
                RoleName       = $CurrentRole.Name
                JsonFile       = $JsonFileName
                JsonPath       = $CreatedFile.FullName
                PrivilegeCount = $PrivilegeIds.Count
                SourceVCenter  = $Connection.Name
                ExportedAt     = $ExportDate
                Status         = "Exported"
            }
        )

        Write-Host "  Privileges : $($PrivilegeIds.Count)" `
            -ForegroundColor DarkGray
        Write-Host "  JSON file  : $JsonFileName" `
            -ForegroundColor DarkGray
    }

    $CsvPath = Join-Path `
        -Path $ExportFolder `
        -ChildPath "RoleInventory.csv"

    $RoleInventory |
        Sort-Object -Property RoleName |
        Export-Csv `
            -LiteralPath $CsvPath `
            -NoTypeInformation `
            -Encoding UTF8 `
            -ErrorAction Stop

    if (-not (Test-Path -LiteralPath $CsvPath)) {
        throw "The role inventory CSV was not created: $CsvPath"
    }

    Write-Host ""
    Write-Host "Export completed successfully." -ForegroundColor Green
    Write-Host "--------------------------------" -ForegroundColor Green
    Write-Host "Source vCenter : $($Connection.Name)"
    Write-Host "Exported roles : $($RoleInventory.Count)"
    Write-Host "Export folder  : $ExportFolder"
    Write-Host "Inventory CSV  : $CsvPath"
    Write-Host ""

    $RoleInventory |
        Sort-Object -Property RoleName |
        Format-Table `
            RoleName,
            PrivilegeCount,
            JsonFile,
            Status `
            -AutoSize
}
catch {
    Write-Host ""
    Write-Host "Role export failed." -ForegroundColor Red
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