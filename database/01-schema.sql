/*
  ClaimSnap - Azure SQL schema (3NF)
  Re-running this script rebuilds the tables and seed data.
*/

DROP VIEW IF EXISTS dbo.vw_Evidence;
DROP TABLE IF EXISTS dbo.AuditLog, dbo.EvidenceItem, dbo.Claim, dbo.AppUser, dbo.StormEvent;
GO

CREATE TABLE dbo.StormEvent (
    eventId       int IDENTITY PRIMARY KEY,
    eventName     varchar(80) NOT NULL,
    eventDateUtc  datetime2   NOT NULL
);

CREATE TABLE dbo.AppUser (
    userId       int IDENTITY PRIMARY KEY,
    displayName  varchar(100) NOT NULL,
    email        varchar(254) NOT NULL UNIQUE,
    role         varchar(20)  NOT NULL CHECK (role IN ('Policyholder', 'Adjuster'))
);

CREATE TABLE dbo.Claim (
    claimId       int IDENTITY PRIMARY KEY,
    claimRef      varchar(20) NOT NULL UNIQUE,
    policyNumber  varchar(30) NOT NULL,
    userId        int NOT NULL REFERENCES dbo.AppUser (userId),
    adjusterId    int NULL     REFERENCES dbo.AppUser (userId),
    eventId       int NOT NULL REFERENCES dbo.StormEvent (eventId),
    status        varchar(20) NOT NULL DEFAULT 'Open' CHECK (status IN ('Open', 'InReview', 'Closed')),
    createdUtc    datetime2   NOT NULL DEFAULT SYSUTCDATETIME()
);

CREATE TABLE dbo.EvidenceItem (
    evidenceId   uniqueidentifier PRIMARY KEY,
    claimId      int NOT NULL REFERENCES dbo.Claim (claimId),
    uploadedBy   int NOT NULL REFERENCES dbo.AppUser (userId),
    fileName     nvarchar(255) NOT NULL,
    fileLocator  varchar(400)  NOT NULL,
    contentType  varchar(20)   NOT NULL CHECK (contentType IN ('image/jpeg', 'image/png')),
    sizeBytes    int           NOT NULL CHECK (sizeBytes BETWEEN 1 AND 10485760),
    sha256       char(64)      NOT NULL,
    caption      nvarchar(500) NULL,
    status       varchar(10)   NOT NULL DEFAULT 'Active' CHECK (status IN ('Active', 'Voided')),
    uploadedUtc  datetime2     NOT NULL DEFAULT SYSUTCDATETIME()
);

-- Serves the retrieve-all query (all evidence for one claim)
CREATE INDEX IX_EvidenceItem_claim_status ON dbo.EvidenceItem (claimId, status) INCLUDE (uploadedUtc);

CREATE TABLE dbo.AuditLog (
    auditId     bigint IDENTITY PRIMARY KEY,
    evidenceId  uniqueidentifier NOT NULL REFERENCES dbo.EvidenceItem (evidenceId),
    userId      int NOT NULL REFERENCES dbo.AppUser (userId),
    action      varchar(10) NOT NULL CHECK (action IN ('Create', 'Update', 'Void')),
    detail      nvarchar(500) NULL,
    atUtc       datetime2 NOT NULL DEFAULT SYSUTCDATETIME()
);
CREATE INDEX IX_AuditLog_evidence ON dbo.AuditLog (evidenceId);
GO

-- Shape returned by the API (lower-case GUID so it matches the Cosmos DB document id)
CREATE VIEW dbo.vw_Evidence AS
SELECT LOWER(CONVERT(char(36), e.evidenceId)) AS evidenceId,
       e.claimId, c.claimRef, e.fileName, e.fileLocator, e.contentType, e.sizeBytes,
       e.sha256, e.caption, e.status, e.uploadedUtc,
       e.uploadedBy, u.displayName AS uploadedByName
FROM dbo.EvidenceItem e
JOIN dbo.Claim c   ON c.claimId = e.claimId
JOIN dbo.AppUser u ON u.userId  = e.uploadedBy;
GO

-- Seed data for the demo scenario
INSERT dbo.StormEvent (eventName, eventDateUtc) VALUES ('Storm Darragh', '2024-12-07');

INSERT dbo.AppUser (displayName, email, role) VALUES
    ('Aoife Byrne',    'aoife.byrne@example.com',    'Policyholder'),   -- userId 1
    ('Daniel Okafor',  'daniel.okafor@example.com',  'Policyholder'),   -- userId 2
    ('Sarah Whitmore', 'sarah.whitmore@example.com', 'Adjuster');       -- userId 3

INSERT dbo.Claim (claimRef, policyNumber, userId, adjusterId, eventId, status) VALUES
    ('CS-24817', 'HH-0093321', 1, 3,    1, 'InReview'),
    ('CS-24818', 'HH-0101874', 2, 3,    1, 'Open'),
    ('CS-24819', 'HH-0093321', 1, NULL, 1, 'Open');
GO

/*
  Least-privilege login for the Logic Apps SQL connection.
  It can only EXECUTE the stored procedures; it cannot read or change tables directly,
  so the AuditLog can only be appended to through the procedures.
*/
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = 'claimsnap_api')
    CREATE USER claimsnap_api WITH PASSWORD = 'tYPEshit_yoyo414#';
GRANT EXECUTE ON SCHEMA::dbo TO claimsnap_api;
GO
