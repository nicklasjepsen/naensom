BEGIN TRY

BEGIN TRAN;

-- AlterTable
ALTER TABLE [dbo].[Space] ADD [pumpCannulaAt] DATETIME2,
[pumpCannulaDays] INT NOT NULL CONSTRAINT [Space_pumpCannulaDays_df] DEFAULT 3,
[pumpCartridgeAt] DATETIME2,
[pumpCartridgeDays] INT NOT NULL CONSTRAINT [Space_pumpCartridgeDays_df] DEFAULT 3;

COMMIT TRAN;

END TRY
BEGIN CATCH

IF @@TRANCOUNT > 0
BEGIN
    ROLLBACK TRAN;
END;
THROW

END CATCH

