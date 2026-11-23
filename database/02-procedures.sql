/*
  ClaimSnap - stored procedures called by the Logic Apps (Execute stored procedure V2).
  Every procedure returns httpStatus in its first result set, so the Logic App can
  respond with the right status code without duplicating business rules.
*/

-- IUPS: register a new evidence item (before the blob and metadata are written)
CREATE OR ALTER PROCEDURE dbo.usp_CreateEvidence
    @evidenceId  uniqueidentifier,
    @claimRef    varchar(20),
    @userId      int,
    @fileName    nvarchar(255),
    @contentType varchar(20),
    @sizeBytes   int,
    @sha256      char(64),
    @caption     nvarchar(500) = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;

    DECLARE @claimId int, @ref varchar(20), @owner int;
    SELECT @claimId = claimId, @ref = claimRef, @owner = userId FROM dbo.Claim WHERE claimRef = @claimRef;

    IF @claimId IS NULL
        BEGIN SELECT 404 AS httpStatus, 'Claim not found' AS error; RETURN; END;
    IF NOT EXISTS (SELECT 1 FROM dbo.AppUser WHERE userId = @userId AND (userId = @owner OR role = 'Adjuster'))
        BEGIN SELECT 403 AS httpStatus, 'You cannot add evidence to this claim' AS error; RETURN; END;
    IF EXISTS (SELECT 1 FROM dbo.EvidenceItem WHERE evidenceId = @evidenceId)
        BEGIN SELECT 409 AS httpStatus, 'This evidence item is already stored' AS error; RETURN; END;

    DECLARE @id char(36) = LOWER(CONVERT(char(36), @evidenceId));
    DECLARE @fileLocator varchar(400) =
        CONCAT('claims/', @ref, '/', @id, IIF(@contentType = 'image/png', '.png', '.jpg'));

    BEGIN TRAN;
        INSERT dbo.EvidenceItem (evidenceId, claimId, uploadedBy, fileName, fileLocator, contentType, sizeBytes, sha256, caption)
        VALUES (@evidenceId, @claimId, @userId, @fileName, @fileLocator, @contentType, @sizeBytes, @sha256, @caption);
        INSERT dbo.AuditLog (evidenceId, userId, action, detail) VALUES (@evidenceId, @userId, 'Create', @fileName);
    COMMIT;

    SELECT 201 AS httpStatus, @id AS evidenceId, @ref AS claimRef, @fileLocator AS fileLocator;
END;
GO

-- IUPS compensation: undo the registration if the blob or metadata write failed
CREATE OR ALTER PROCEDURE dbo.usp_RollbackEvidence
    @evidenceId uniqueidentifier
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    BEGIN TRAN;
        DELETE dbo.AuditLog WHERE evidenceId = @evidenceId AND action = 'Create';
        DELETE dbo.EvidenceItem WHERE evidenceId = @evidenceId
            AND NOT EXISTS (SELECT 1 FROM dbo.AuditLog WHERE evidenceId = @evidenceId);
    COMMIT;
    SELECT 200 AS httpStatus;
END;
GO

-- RAI: claim header (result set 1) and all of its evidence (result set 2)
CREATE OR ALTER PROCEDURE dbo.usp_ListEvidence
    @claimRef varchar(20)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @claimId int = (SELECT claimId FROM dbo.Claim WHERE claimRef = @claimRef);

    IF @claimId IS NULL
        SELECT 404 AS httpStatus, 'Claim not found' AS error;
    ELSE
        SELECT 200 AS httpStatus, c.claimRef, c.policyNumber, c.status AS claimStatus,
               s.eventName, p.displayName AS policyholder, a.displayName AS adjuster
        FROM dbo.Claim c
        JOIN dbo.StormEvent s ON s.eventId = c.eventId
        JOIN dbo.AppUser p    ON p.userId  = c.userId
        LEFT JOIN dbo.AppUser a ON a.userId = c.adjusterId
        WHERE c.claimId = @claimId;

    SELECT evidenceId, claimRef, fileName, fileLocator, contentType, sizeBytes, sha256,
           caption, status, uploadedUtc, uploadedBy, uploadedByName
    FROM dbo.vw_Evidence
    WHERE claimId = @claimId
    ORDER BY uploadedUtc DESC;
END;
GO

-- RIPS: one evidence item (result set 1) and its audit trail (result set 2)
CREATE OR ALTER PROCEDURE dbo.usp_GetEvidence
    @evidenceId uniqueidentifier
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM dbo.EvidenceItem WHERE evidenceId = @evidenceId)
        BEGIN SELECT 404 AS httpStatus, 'Evidence not found' AS error; RETURN; END;

    SELECT 200 AS httpStatus, evidenceId, claimRef, fileName, fileLocator, contentType, sizeBytes,
           sha256, caption, status, uploadedUtc, uploadedBy, uploadedByName
    FROM dbo.vw_Evidence WHERE evidenceId = LOWER(CONVERT(char(36), @evidenceId));

    SELECT l.action, l.detail, l.atUtc, u.displayName AS byUser
    FROM dbo.AuditLog l JOIN dbo.AppUser u ON u.userId = l.userId
    WHERE l.evidenceId = @evidenceId
    ORDER BY l.atUtc;
END;
GO

-- UIPS: edit the caption (the original photo is never overwritten)
CREATE OR ALTER PROCEDURE dbo.usp_UpdateEvidence
    @evidenceId uniqueidentifier,
    @userId     int,
    @caption    nvarchar(500) = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;

    DECLARE @status varchar(10), @uploadedBy int;
    SELECT @status = status, @uploadedBy = uploadedBy FROM dbo.EvidenceItem WHERE evidenceId = @evidenceId;

    IF @status IS NULL
        BEGIN SELECT 404 AS httpStatus, 'Evidence not found' AS error; RETURN; END;
    IF NOT EXISTS (SELECT 1 FROM dbo.AppUser WHERE userId = @userId AND (userId = @uploadedBy OR role = 'Adjuster'))
        BEGIN SELECT 403 AS httpStatus, 'You cannot edit this evidence item' AS error; RETURN; END;
    IF @status = 'Voided'
        BEGIN SELECT 409 AS httpStatus, 'Voided evidence cannot be edited' AS error; RETURN; END;

    BEGIN TRAN;
        UPDATE dbo.EvidenceItem SET caption = @caption WHERE evidenceId = @evidenceId;
        INSERT dbo.AuditLog (evidenceId, userId, action, detail) VALUES (@evidenceId, @userId, 'Update', @caption);
    COMMIT;

    SELECT 200 AS httpStatus, evidenceId, claimRef, fileName, fileLocator, contentType, sizeBytes,
           sha256, caption, status, uploadedUtc, uploadedBy, uploadedByName
    FROM dbo.vw_Evidence WHERE evidenceId = LOWER(CONVERT(char(36), @evidenceId));
END;
GO

-- DIPS: soft delete. The item is voided and audited; the blob is kept for the retention period.
CREATE OR ALTER PROCEDURE dbo.usp_VoidEvidence
    @evidenceId uniqueidentifier,
    @userId     int,
    @reason     nvarchar(500) = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;

    DECLARE @status varchar(10) = (SELECT status FROM dbo.EvidenceItem WHERE evidenceId = @evidenceId);

    IF @status IS NULL
        BEGIN SELECT 404 AS httpStatus, 'Evidence not found' AS error; RETURN; END;
    IF NOT EXISTS (SELECT 1 FROM dbo.AppUser WHERE userId = @userId AND role = 'Adjuster')
        BEGIN SELECT 403 AS httpStatus, 'Only an adjuster can void evidence' AS error; RETURN; END;
    IF @status = 'Voided'
        BEGIN SELECT 409 AS httpStatus, 'Evidence is already voided' AS error; RETURN; END;

    BEGIN TRAN;
        UPDATE dbo.EvidenceItem SET status = 'Voided' WHERE evidenceId = @evidenceId;
        INSERT dbo.AuditLog (evidenceId, userId, action, detail) VALUES (@evidenceId, @userId, 'Void', @reason);
    COMMIT;

    SELECT 204 AS httpStatus;
END;
GO
