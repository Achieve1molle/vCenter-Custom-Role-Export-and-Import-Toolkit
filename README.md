# vCenter-Custom-Role-Export-and-Import-Toolkit
# vCenter Custom Role Export and Import Toolkit

This toolkit exports custom role definitions from one vCenter Server and imports selected role definitions into either a single vCenter or multiple vCenters.

## Included files

- `ExportvCenterRoles.ps1` — exports custom roles from a source vCenter.
- `ImportvCenterRolesSingle.ps1` — imports role definitions into one destination vCenter.
- `ImportvCenterRolesMulti.ps1` — imports role definitions into multiple destination vCenters.
- `vcenters.txt` — optional list of destination vCenters used by the multi-vCenter importer.
- `vCenterRoles\` — default folder containing exported JSON role definitions, the role inventory CSV, and import result reports.

## Important behavior

- The export script exports **all custom/non-system roles** by default.
- Each role is stored in a separate JSON file named for the role.
- The import scripts process every JSON file remaining in the import folder unless a role-name filter is used.
- After exporting, review the JSON files and **delete or move any role definitions that should not be imported**. In most cases, only a selected subset of the exported roles should be deployed to the destination vCenter systems.
- Existing destination roles are skipped by default to avoid unintentionally modifying production permissions.
- These scripts migrate **role definitions and their privilege IDs only**. They do not migrate user/group assignments, inventory permissions, propagation settings, or object-level permission assignments.

## Prerequisites

1. Windows PowerShell 7 or another PowerShell version supported by the installed PowerCLI release.
2. VCF PowerCLI/VMware PowerCLI installed and available in the PowerShell session.
3. Network and DNS connectivity to every source and destination vCenter.
4. An SSO account with sufficient privileges to read roles on the source vCenter and create roles on each destination vCenter.
5. The scripts stored in `C:\Staging` unless the example paths are adjusted.

Example working folder:

```text
C:\Staging\
├── ExportvCenterRoles.ps1
├── ImportvCenterRolesSingle.ps1
├── ImportvCenterRolesMulti.ps1
├── vcenters.txt
└── vCenterRoles\
```

## Recommended workflow

1. Export roles from the source vCenter.
2. Review `RoleInventory.csv` and the JSON files in `C:\Staging\vCenterRoles`.
3. Delete or move JSON files for roles that should not be imported.
4. Test the single- or multi-vCenter import with `-WhatIf`.
5. Review the console output and generated results CSV.
6. Run the import again without `-WhatIf` to create the roles.
7. Verify the resulting roles in each destination vCenter.

---

# 1. Export roles from a source vCenter

## Script

```text
ExportvCenterRoles.ps1
```

## Purpose

The export script connects to a source vCenter and exports custom/non-system role definitions. It creates:

- One JSON file per role.
- `RoleInventory.csv`, containing a summary of the exported roles.

## Export all custom roles

From `C:\Staging`, run:

```powershell
.\ExportvCenterRoles.ps1 `
    -SourceVC "source-vcenter.example.com" `
    -ExportFolder "C:\Staging\vCenterRoles"
```

PowerShell prompts for vCenter credentials when needed.

## Export selected roles only

If supported by the script, selected role names can be supplied with `-RoleName`:

```powershell
.\ExportvCenterRoles.ps1 `
    -SourceVC "source-vcenter.example.com" `
    -ExportFolder "C:\Staging\vCenterRoles" `
    -RoleName "Backup Operator","Monitoring Role"
```

## Review and clean the exported files

The default export includes all custom roles. Before importing, open:

```text
C:\Staging\vCenterRoles
```

Review `RoleInventory.csv` and each JSON file. **Delete or move every JSON role file that should not be pushed to the destination environment.**

For example, if the export folder contains ten JSON files but only two roles are needed, leave only those two JSON files in the folder before running an importer. Do not delete `RoleInventory.csv`; the import scripts process `.json` files only.

Example after cleanup:

```text
C:\Staging\vCenterRoles\
├── Backup Operator.json
├── Monitoring Role.json
└── RoleInventory.csv
```

---

# 2. Import roles into a single vCenter

## Script

```text
ImportvCenterRolesSingle.ps1
```

## Purpose

The single-vCenter importer reads the JSON role definitions in the import folder and creates the roles on one destination vCenter.

## Test the import first

Use `-WhatIf` to validate the JSON files, destination privileges, and existing roles without creating anything:

```powershell
.\ImportvCenterRolesSingle.ps1 `
    -DestinationVC "destination-vcenter.example.com" `
    -ImportFolder "C:\Staging\vCenterRoles" `
    -WhatIf
```

## Perform the import

After reviewing the test output, run the same command without `-WhatIf`:

```powershell
.\ImportvCenterRolesSingle.ps1 `
    -DestinationVC "destination-vcenter.example.com" `
    -ImportFolder "C:\Staging\vCenterRoles"
```

## Expected behavior

- Every JSON file in `C:\Staging\vCenterRoles` is evaluated.
- A role is created when the role does not already exist and at least one requested privilege is available.
- Existing roles are skipped.
- Privilege IDs unavailable on the destination are reported.
- A CSV results report is written to the import folder.

---

# 3. Import roles into multiple vCenters

## Script

```text
ImportvCenterRolesMulti.ps1
```

## Purpose

The multi-vCenter importer reads the selected JSON role definitions and pushes the roles to every vCenter listed in a text file. The same SSO credential can be reused for the vCenters when the account is authorized across the environment.

## Create the vCenter list file

Create this file:

```text
C:\Staging\vcenters.txt
```

Add one vCenter FQDN or resolvable hostname per line. Do not add commas, quotation marks, or PowerShell syntax.

Example:

```text
vcsa01.example.com
vcsa02.example.com
vcsa03.example.com
```

Blank lines are ignored. Ensure every listed vCenter is reachable and that the SSO account has permission to create roles on every target.

## Test the multi-vCenter import

Run the following format from `C:\Staging`:

```powershell
.\ImportvCenterRolesMulti.ps1 `
    -DestinationVCFile "C:\Staging\vcenters.txt" `
    -ImportFolder "C:\Staging\vCenterRoles" `
    -WhatIf
```

The backtick at the end of each continued line must be the final character on that line. Do not place spaces after the backtick.

## Perform the multi-vCenter import

After reviewing the `-WhatIf` output, run:

```powershell
.\ImportvCenterRolesMulti.ps1 `
    -DestinationVCFile "C:\Staging\vcenters.txt" `
    -ImportFolder "C:\Staging\vCenterRoles"
```

The script prompts once for an SSO credential unless a credential is supplied through a supported script parameter. It then processes each listed vCenter separately.

## Update existing roles, if required

By default, existing roles are skipped. If the script supports the `-UpdateExistingRoles` switch, use it only after testing carefully:

```powershell
.\ImportvCenterRolesMulti.ps1 `
    -DestinationVCFile "C:\Staging\vcenters.txt" `
    -ImportFolder "C:\Staging\vCenterRoles" `
    -UpdateExistingRoles `
    -WhatIf
```

Remove `-WhatIf` only after reviewing the proposed changes. The update mode is intended to add missing exported privileges; confirm the script behavior before using it in production.

## Expected behavior

For each vCenter, the script:

1. Connects using the supplied SSO credential.
2. Retrieves available privileges and existing roles.
3. Processes each JSON role definition in the import folder.
4. Creates missing roles.
5. Skips existing roles unless update mode is explicitly enabled.
6. Reports missing or version-specific privilege IDs.
7. Continues to the next vCenter when an individual target fails.
8. Writes a consolidated results CSV to the role folder.

---

# Validate script syntax

The following example checks a script for PowerShell parser errors before it is run:

```powershell
$ScriptPath = "C:\Staging\ImportvCenterRolesMulti.ps1"
$Tokens = $null
$ParseErrors = $null

[System.Management.Automation.Language.Parser]::ParseFile(
    $ScriptPath,
    [ref]$Tokens,
    [ref]$ParseErrors
) | Out-Null

if ($ParseErrors.Count -eq 0) {
    Write-Host "Script syntax is valid." -ForegroundColor Green
}
else {
    $ParseErrors | Format-List Message, Extent
}
```

Change `$ScriptPath` to validate either of the other scripts.

# Troubleshooting

## Parameter set cannot be resolved

For the multi-vCenter script, supply one destination method. The recommended method is:

```powershell
-DestinationVCFile "C:\Staging\vcenters.txt"
```

Do not supply `-DestinationVC` and `-DestinationVCFile` together.

## No JSON files found

Confirm that the following folder exists and contains at least one `.json` file:

```text
C:\Staging\vCenterRoles
```

## Role already exists

Existing roles are skipped by design. Review the generated CSV report. Use an update option only when the existing role should intentionally be modified and after first testing with `-WhatIf`.

## Missing privileges

Privilege availability can vary between vCenter versions or configurations. The importer reports unavailable privilege IDs and applies only those found on the destination. Review all missing privileges before relying on the imported role.

## Authentication or authorization failure

Confirm that:

- The hostname resolves and TCP 443 is reachable.
- The supplied SSO credential is valid.
- The account has permission to manage roles on every destination vCenter.
- The vCenter certificate and PowerCLI certificate handling configuration are appropriate for the environment.

# Safety and operational notes

- Always run imports with `-WhatIf` first.
- Keep a backup copy of the original JSON export outside the working import folder.
- Remove unneeded JSON files from the active import folder before deployment.
- Review the results CSV after every run.
- Verify imported roles in the vSphere/VCF management interface.
- Assign users or groups to imported roles separately; role creation alone does not grant access.

