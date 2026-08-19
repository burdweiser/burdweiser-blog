-- =============================================================================
-- ESXi Branch Patching Portal — SQL Server Schema
-- Compatible with: SQL Server 2019+
-- Authentication: Windows Auth (Integrated Security). No SQL logins required.
--
-- Usage:
--   1. Create the database first:
--        CREATE DATABASE ESXiPatchPortal;
--   2. Run this script in the context of that database:
--        USE ESXiPatchPortal;
--   3. Update the GRANT statements at the bottom with your actual
--      IIS App Pool account and job service account names.
-- =============================================================================

USE ESXiPatchPortal;
GO

-- =============================================================================
-- 1. QueryRuns
--    One row per time an operator runs the "Discover Hosts" query in the portal.
--    Provides the audit anchor (QueryRunId) for VMInventorySnapshots.
-- =============================================================================
CREATE TABLE dbo.QueryRuns (
    QueryRunId       INT           IDENTITY(1,1) PRIMARY KEY,
    RunByUser        NVARCHAR(128) NOT NULL,                        -- portal login / UPN
    DatacenterName   NVARCHAR(256) NOT NULL,
    TotalHosts       INT           NULL,                            -- filled in after PS script completes
    StandaloneHosts  INT           NULL,
    ClusteredHosts   INT           NULL,
    StartedAt        DATETIME2     NOT NULL DEFAULT GETUTCDATE(),
    CompletedAt      DATETIME2     NULL,
    Status           NVARCHAR(32)  NOT NULL DEFAULT 'Running'      -- Running | Completed | Failed
);
GO

-- =============================================================================
-- 2. SiteVMs
--    Live VM inventory — one row per VM per site.
--    This is the working table jobs read at execution time.
--    CustomOrdered = 1 protects manually set order from being overwritten on resync.
-- =============================================================================
CREATE TABLE dbo.SiteVMs (
    SiteVMId         INT           IDENTITY(1,1) PRIMARY KEY,
    SiteName         NVARCHAR(256) NOT NULL,
    VMName           NVARCHAR(256) NOT NULL,
    HostName         NVARCHAR(256) NOT NULL,
    VMType           NVARCHAR(32)  NOT NULL DEFAULT 'APP',         -- APP | SQL | DC
    CurrentVersion   NVARCHAR(64)  NULL,                           -- ESXi version string from host
    ShutdownOrder    INT           NOT NULL DEFAULT 1,             -- lower = shut down earlier
    PowerOnOrder     INT           NOT NULL DEFAULT 3,             -- lower = powered on earlier
    CustomOrdered    BIT           NOT NULL DEFAULT 0,             -- 1 = operator set manually; skip on resync
    LastQueryRunId   INT           NOT NULL,
    UpdatedAt        DATETIME2     NOT NULL DEFAULT GETUTCDATE(),
    CONSTRAINT UQ_SiteVMs_Site_VM UNIQUE (SiteName, VMName),
    CONSTRAINT FK_SiteVMs_QueryRun FOREIGN KEY (LastQueryRunId) REFERENCES dbo.QueryRuns(QueryRunId)
);
GO

CREATE INDEX IX_SiteVMs_SiteName ON dbo.SiteVMs (SiteName);
GO

-- =============================================================================
-- 3. VMInventorySnapshots
--    Immutable copy of the VM list as it existed at each QueryRunId.
--    Never updated after insert — provides a point-in-time audit history
--    of exactly what VMs were present (and in what order) when a job ran.
-- =============================================================================
CREATE TABLE dbo.VMInventorySnapshots (
    SnapshotId       INT           IDENTITY(1,1) PRIMARY KEY,
    QueryRunId       INT           NOT NULL,
    SiteName         NVARCHAR(256) NOT NULL,
    VMName           NVARCHAR(256) NOT NULL,
    HostName         NVARCHAR(256) NOT NULL,
    VMType           NVARCHAR(32)  NOT NULL,
    ShutdownOrder    INT           NOT NULL,
    PowerOnOrder     INT           NOT NULL,
    CreatedAt        DATETIME2     NOT NULL DEFAULT GETUTCDATE(),
    CONSTRAINT FK_VMSnapshots_QueryRun FOREIGN KEY (QueryRunId) REFERENCES dbo.QueryRuns(QueryRunId)
);
GO

CREATE INDEX IX_VMSnapshots_QueryRunId ON dbo.VMInventorySnapshots (QueryRunId);
GO

-- =============================================================================
-- 4. Jobs
--    One row per batch patching job created in the portal.
-- =============================================================================
CREATE TABLE dbo.Jobs (
    JobId            INT           IDENTITY(1,1) PRIMARY KEY,
    JobName          NVARCHAR(256) NOT NULL,
    TargetVersion    NVARCHAR(64)  NOT NULL,                       -- e.g. "8.0 U3k"
    TargetBuild      NVARCHAR(32)  NOT NULL,                       -- e.g. "24674316"
    ScheduledTimeUtc DATETIME2     NOT NULL,
    MaxParallelSites INT           NOT NULL DEFAULT 5,
    RunAsAccount     NVARCHAR(256) NOT NULL,                       -- DOMAIN\svc-esxipatch
    CreatedBy        NVARCHAR(256) NOT NULL,                       -- portal user (audit only)
    QueryRunId       INT           NOT NULL,                       -- inventory snapshot used
    Status           NVARCHAR(32)  NOT NULL DEFAULT 'Scheduled',  -- Scheduled | Running | Completed | Failed | Cancelled
    TaskSchedulerJob NVARCHAR(256) NULL,                           -- Task Scheduler task name
    CreatedAt        DATETIME2     NOT NULL DEFAULT GETUTCDATE(),
    StartedAt        DATETIME2     NULL,
    CompletedAt      DATETIME2     NULL,
    Notes            NVARCHAR(MAX) NULL,
    CONSTRAINT FK_Jobs_QueryRun FOREIGN KEY (QueryRunId) REFERENCES dbo.QueryRuns(QueryRunId)
);
GO

-- =============================================================================
-- 5. JobSites
--    Which sites are included in each job, with per-site state.
--    The patching script updates Status and timestamps as it progresses.
-- =============================================================================
CREATE TABLE dbo.JobSites (
    JobSiteId        INT           IDENTITY(1,1) PRIMARY KEY,
    JobId            INT           NOT NULL,
    SiteName         NVARCHAR(256) NOT NULL,
    HostMoRef        NVARCHAR(64)  NULL,                           -- e.g. "host-42"
    CurrentESXiVer   NVARCHAR(64)  NULL,
    TargetESXiVer    NVARCHAR(64)  NULL,
    Status           NVARCHAR(64)  NOT NULL DEFAULT 'Queued',
    -- Status values: Queued | ShuttingDownVMs | InMaintenanceMode
    --                Remediating | ExitingMaintenance | PoweringOnVMs | Completed | Failed
    VcTaskId         NVARCHAR(256) NULL,                           -- vCenter task ID from POST .../software?action=apply
    RemediationPct   INT           NULL,                           -- 0-100 polled from vCenter task
    StartedAt        DATETIME2     NULL,
    CompletedAt      DATETIME2     NULL,
    ErrorMessage     NVARCHAR(MAX) NULL,
    CONSTRAINT FK_JobSites_Job  FOREIGN KEY (JobId)   REFERENCES dbo.Jobs(JobId),
    CONSTRAINT UQ_JobSites      UNIQUE (JobId, SiteName)
);
GO

CREATE INDEX IX_JobSites_JobId ON dbo.JobSites (JobId);
GO

-- =============================================================================
-- 6. AuditLog
--    Append-only event log. Never updated — rows are only INSERTed.
-- =============================================================================
CREATE TABLE dbo.AuditLog (
    AuditId          INT           IDENTITY(1,1) PRIMARY KEY,
    EventTimeUtc     DATETIME2     NOT NULL DEFAULT GETUTCDATE(),
    Actor            NVARCHAR(256) NOT NULL,                       -- user or service account
    EventType        NVARCHAR(64)  NOT NULL,
    -- EventType values: QueryRun | JobCreated | JobStarted | SiteCompleted
    --                   SiteFailed | JobCompleted | JobCancelled | VMOrderChanged
    JobId            INT           NULL,
    SiteName         NVARCHAR(256) NULL,
    Detail           NVARCHAR(MAX) NULL
);
GO

CREATE INDEX IX_AuditLog_EventTime ON dbo.AuditLog (EventTimeUtc DESC);
CREATE INDEX IX_AuditLog_JobId     ON dbo.AuditLog (JobId);
GO

-- =============================================================================
-- GRANTS
-- Replace the account names below with your actual service accounts.
--
--   [IIS_SERVICE_ACCOUNT]  — the IIS App Pool identity
--                            (reads/writes inventory, creates jobs, writes audit)
--   [JOB_SERVICE_ACCOUNT]  — the Task Scheduler job account (svc-esxipatch)
--                            (reads inventory, updates job state, writes audit)
-- =============================================================================

-- IIS App Pool account
GRANT SELECT, INSERT, UPDATE        ON dbo.QueryRuns            TO [DOMAIN\svc-iis-esxiportal];
GRANT SELECT, INSERT, UPDATE, DELETE ON dbo.SiteVMs             TO [DOMAIN\svc-iis-esxiportal];
GRANT SELECT, INSERT                ON dbo.VMInventorySnapshots TO [DOMAIN\svc-iis-esxiportal];
GRANT SELECT, INSERT, UPDATE        ON dbo.Jobs                 TO [DOMAIN\svc-iis-esxiportal];
GRANT SELECT, INSERT, UPDATE        ON dbo.JobSites             TO [DOMAIN\svc-iis-esxiportal];
GRANT SELECT, INSERT                ON dbo.AuditLog             TO [DOMAIN\svc-iis-esxiportal];
GO

-- Job execution service account
GRANT SELECT                        ON dbo.QueryRuns            TO [DOMAIN\svc-esxipatch];
GRANT SELECT, UPDATE                ON dbo.SiteVMs              TO [DOMAIN\svc-esxipatch];
GRANT SELECT                        ON dbo.VMInventorySnapshots TO [DOMAIN\svc-esxipatch];
GRANT SELECT, UPDATE                ON dbo.Jobs                 TO [DOMAIN\svc-esxipatch];
GRANT SELECT, UPDATE                ON dbo.JobSites             TO [DOMAIN\svc-esxipatch];
GRANT SELECT, INSERT                ON dbo.AuditLog             TO [DOMAIN\svc-esxipatch];
GO
