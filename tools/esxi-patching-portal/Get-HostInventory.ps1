#Requires -Modules VMware.PowerCLI
#James Burd - Burdweiser.com AUG2026
<#
.SYNOPSIS
    Discovers standalone ESXi hosts in a vCenter datacenter object and writes
    VM inventory to SQL Server for the ESXi branch patching portal.

.DESCRIPTION
    Connects to vCenter, enumerates all VMHosts in the specified Datacenter,
    filters OUT any host that belongs to a cluster, then collects the VM list
    and default shutdown/power-on ordering for each standalone host.

    Default ordering heuristic:
      - Shutdown: DC last (highest ShutdownOrder number), SQL second-to-last, others first
      - Power-on:  DC first (lowest PowerOnOrder number), SQL second, others last

    Results are MERGE/UPSERTed into SQL.  Rows with CustomOrdered = 1 retain
    their manually set order values.

.PARAMETER VCenterFqdn
    FQDN or IP of the vCenter Server.  Example: vcenter.corp.local

.PARAMETER DatacenterName
    Name of the vCenter Datacenter object to query.  Example: "Branch Offices"

.PARAMETER SqlServer
    SQL Server instance.  Example: SQL01\PATCHING

.PARAMETER SqlDatabase
    Database name.  Example: ESXiPatchPortal

.PARAMETER CredentialFile
    Path to a DPAPI-encrypted credential XML produced by Export-Clixml.
    Must be encrypted by the same Windows account that will run this script.
    Example: C:\Secrets\vcenter-svc-cred.xml

.PARAMETER QueryRunId
    Integer ID of the QueryRun row in SQL (created by the calling API before
    invoking this script).  Used to key VMInventorySnapshots rows.

.EXAMPLE
    .\Get-HostInventory.ps1 `
        -VCenterFqdn   vcenter.corp.local `
        -DatacenterName "Branch Offices" `
        -SqlServer      SQL01 `
        -SqlDatabase    ESXiPatchPortal `
        -CredentialFile C:\Secrets\vcenter-svc-cred.xml `
        -QueryRunId     42
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $VCenterFqdn,
    [Parameter(Mandatory)] [string] $DatacenterName,
    [Parameter(Mandatory)] [string] $SqlServer,
    [Parameter(Mandatory)] [string] $SqlDatabase,
    [Parameter(Mandatory)] [string] $CredentialFile,
    [Parameter(Mandatory)] [int]    $QueryRunId
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# 1. Helper: SQL connection (Windows auth — no passwords in this script)
# ---------------------------------------------------------------------------
function Get-SqlConnection {
    $connStr = "Server=$SqlServer;Database=$SqlDatabase;Integrated Security=True;"
    $conn = New-Object System.Data.SqlClient.SqlConnection($connStr)
    $conn.Open()
    return $conn
}

# ---------------------------------------------------------------------------
# 2. Determine VM type from name patterns (adjust regexes for your environment)
# ---------------------------------------------------------------------------
function Get-VMType ([string]$VMName) {
    if ($VMName -match '(?i)(sql|db\d|database)') { return 'SQL'  }
    if ($VMName -match '(?i)(dc\d|domainctrl|addc)') { return 'DC'   }
    return 'APP'
}

# ---------------------------------------------------------------------------
# 3. Shutdown order: APP=1, SQL=2, DC=3 (DC stays up longest)
#    Power-on order: DC=1, SQL=2, APP=3 (DC comes up first)
# ---------------------------------------------------------------------------
function Get-Orders ([string]$VMType) {
    switch ($VMType) {
        'DC'  { return @{ ShutdownOrder = 3; PowerOnOrder = 1 } }
        'SQL' { return @{ ShutdownOrder = 2; PowerOnOrder = 2 } }
        default { return @{ ShutdownOrder = 1; PowerOnOrder = 3 } }
    }
}

# ---------------------------------------------------------------------------
# 4. Connect to vCenter
# ---------------------------------------------------------------------------
Write-Host "[$(Get-Date -f 'HH:mm:ss')] Connecting to vCenter: $VCenterFqdn"
$cred = Import-Clixml -Path $CredentialFile
Connect-VIServer -Server $VCenterFqdn -Credential $cred -Force | Out-Null
Write-Host "[$(Get-Date -f 'HH:mm:ss')] Connected."

try {
    # -----------------------------------------------------------------------
    # 5. Get all hosts in the datacenter, filter to standalone only
    # -----------------------------------------------------------------------
    $dc       = Get-Datacenter -Name $DatacenterName -ErrorAction Stop
    $allHosts = Get-VMHost -Location $dc

    $standaloneHosts = $allHosts | Where-Object {
        ($_ | Get-Cluster -ErrorAction SilentlyContinue) -eq $null
    }

    $totalCount      = $allHosts.Count
    $standaloneCount = $standaloneHosts.Count
    $clusteredCount  = $totalCount - $standaloneCount

    Write-Host "[$(Get-Date -f 'HH:mm:ss')] $totalCount total hosts · $standaloneCount standalone · $clusteredCount clustered (excluded)"

    # -----------------------------------------------------------------------
    # 6. Open SQL connection, prepare MERGE statements
    # -----------------------------------------------------------------------
    $conn = Get-SqlConnection

    $mergeSiteVMs = @"
MERGE SiteVMs AS target
USING (VALUES (@SiteName, @VMName, @HostName, @VMType, @CurrentVersion, @ShutdownOrder, @PowerOnOrder, @QueryRunId))
      AS source (SiteName, VMName, HostName, VMType, CurrentVersion, ShutdownOrder, PowerOnOrder, LastQueryRunId)
ON target.SiteName = source.SiteName AND target.VMName = source.VMName
WHEN MATCHED THEN
    UPDATE SET
        HostName       = source.HostName,
        VMType         = source.VMType,
        CurrentVersion = source.CurrentVersion,
        LastQueryRunId = source.LastQueryRunId,
        ShutdownOrder  = CASE WHEN target.CustomOrdered = 0 THEN source.ShutdownOrder ELSE target.ShutdownOrder END,
        PowerOnOrder   = CASE WHEN target.CustomOrdered = 0 THEN source.PowerOnOrder  ELSE target.PowerOnOrder  END
WHEN NOT MATCHED THEN
    INSERT (SiteName, VMName, HostName, VMType, CurrentVersion, ShutdownOrder, PowerOnOrder, LastQueryRunId, CustomOrdered)
    VALUES (source.SiteName, source.VMName, source.HostName, source.VMType, source.CurrentVersion,
            source.ShutdownOrder, source.PowerOnOrder, source.LastQueryRunId, 0);
"@

    $insertSnapshot = @"
INSERT INTO VMInventorySnapshots
    (QueryRunId, SiteName, VMName, HostName, VMType, ShutdownOrder, PowerOnOrder)
VALUES
    (@QueryRunId, @SiteName, @VMName, @HostName, @VMType, @ShutdownOrder, @PowerOnOrder);
"@

    # -----------------------------------------------------------------------
    # 7. Process each standalone host
    # -----------------------------------------------------------------------
    foreach ($vmHost in $standaloneHosts) {
        $siteName       = $vmHost.Name   # adjust if your host naming differs from site naming
        $currentVersion = $vmHost.Version
        $hostName       = $vmHost.Name

        Write-Host "[$(Get-Date -f 'HH:mm:ss')] Processing: $siteName  (ESXi $currentVersion)"

        $vms = Get-VM -Location $vmHost | Sort-Object Name

        foreach ($vm in $vms) {
            $vmType = Get-VMType -VMName $vm.Name
            $orders = Get-Orders -VMType $vmType

            # MERGE into SiteVMs
            $cmd = $conn.CreateCommand()
            $cmd.CommandText = $mergeSiteVMs
            $cmd.Parameters.AddWithValue('@SiteName',       $siteName)       | Out-Null
            $cmd.Parameters.AddWithValue('@VMName',         $vm.Name)        | Out-Null
            $cmd.Parameters.AddWithValue('@HostName',       $hostName)       | Out-Null
            $cmd.Parameters.AddWithValue('@VMType',         $vmType)         | Out-Null
            $cmd.Parameters.AddWithValue('@CurrentVersion', $currentVersion) | Out-Null
            $cmd.Parameters.AddWithValue('@ShutdownOrder',  $orders.ShutdownOrder) | Out-Null
            $cmd.Parameters.AddWithValue('@PowerOnOrder',   $orders.PowerOnOrder)  | Out-Null
            $cmd.Parameters.AddWithValue('@QueryRunId',     $QueryRunId)     | Out-Null
            $cmd.ExecuteNonQuery() | Out-Null

            # Append to immutable snapshot
            $snap = $conn.CreateCommand()
            $snap.CommandText = $insertSnapshot
            $snap.Parameters.AddWithValue('@QueryRunId',    $QueryRunId)           | Out-Null
            $snap.Parameters.AddWithValue('@SiteName',      $siteName)             | Out-Null
            $snap.Parameters.AddWithValue('@VMName',        $vm.Name)              | Out-Null
            $snap.Parameters.AddWithValue('@HostName',      $hostName)             | Out-Null
            $snap.Parameters.AddWithValue('@VMType',        $vmType)               | Out-Null
            $snap.Parameters.AddWithValue('@ShutdownOrder', $orders.ShutdownOrder) | Out-Null
            $snap.Parameters.AddWithValue('@PowerOnOrder',  $orders.PowerOnOrder)  | Out-Null
            $snap.ExecuteNonQuery() | Out-Null
        }
    }

    $conn.Close()

    # -----------------------------------------------------------------------
    # 8. Update QueryRuns with final counts
    # -----------------------------------------------------------------------
    $conn2 = Get-SqlConnection
    $upd = $conn2.CreateCommand()
    $upd.CommandText = @"
UPDATE QueryRuns
SET TotalHosts      = @Total,
    StandaloneHosts = @Standalone,
    ClusteredHosts  = @Clustered,
    CompletedAt     = GETUTCDATE(),
    Status          = 'Completed'
WHERE QueryRunId = @QueryRunId;
"@
    $upd.Parameters.AddWithValue('@Total',      $totalCount)      | Out-Null
    $upd.Parameters.AddWithValue('@Standalone', $standaloneCount) | Out-Null
    $upd.Parameters.AddWithValue('@Clustered',  $clusteredCount)  | Out-Null
    $upd.Parameters.AddWithValue('@QueryRunId', $QueryRunId)      | Out-Null
    $upd.ExecuteNonQuery() | Out-Null
    $conn2.Close()

    Write-Host "[$(Get-Date -f 'HH:mm:ss')] Inventory sync complete. QueryRunId: $QueryRunId"
}
finally {
    Disconnect-VIServer -Server $VCenterFqdn -Confirm:$false -ErrorAction SilentlyContinue
}