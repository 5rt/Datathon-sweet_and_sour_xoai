-- =====================================================================
-- 04_sources.sql
-- Library cards: where every file came from.
--   1. Starter cards for the original files (real names in the stage)
--   2. Cards read automatically from source_manifest.json
--   3. A list of any files still missing a card, as ready-to-fill lines
-- Safe to re-run: existing cards (including ones added in the app) are kept.
-- =====================================================================

USE ROLE EVIDENCE_DEV;
USE WAREHOUSE EVIDENCE_WH;
USE SCHEMA EVIDENCE_DB.CORE;

CREATE FILE FORMAT IF NOT EXISTS JSON_FF TYPE = JSON STRIP_OUTER_ARRAY = TRUE;

CREATE TABLE IF NOT EXISTS SOURCE_REGISTER (
    file_name               STRING,
    title                   STRING,
    publisher               STRING,
    source_url              STRING,
    doc_type                STRING,
    primary_drug            STRING,      -- NULL = worked out from the vocabulary; 'multiple' = several drugs
    downloaded_on           DATE,
    why_chosen              STRING,
    contains_personal_info  BOOLEAN DEFAULT FALSE
);

-- ---------------------------------------------------------------------
-- 1. Starter cards
-- ---------------------------------------------------------------------
MERGE INTO SOURCE_REGISTER t
USING (
    SELECT * FROM VALUES
      ('ibrancecap.pdf',
       'New Zealand Data Sheet - Ibrance (palbociclib)', 'Medsafe',
       'https://www.medsafe.govt.nz/profs/Datasheet/i/ibrancecap.pdf',
       'Data sheet', NULL, 'Official NZ product information with adverse reaction rates'),
      ('verzeniotab.pdf',
       'New Zealand Data Sheet - Verzenio (abemaciclib)', 'Medsafe',
       'https://www.medsafe.govt.nz/Profs/Datasheet/v/verzeniotab.pdf',
       'Data sheet', NULL, 'Official NZ product information with adverse reaction rates'),
      ('Kisqalitab.pdf',
       'New Zealand Data Sheet - Kisqali (ribociclib)', 'Medsafe',
       'https://www.medsafe.govt.nz/profs/Datasheet/k/Kisqalitab.pdf',
       'Data sheet', NULL, 'Official NZ product information with adverse reaction rates'),
      ('212436s008lbl.pdf',
       'Ibrance (palbociclib) Prescribing Information', 'US FDA',
       'https://www.accessdata.fda.gov/drugsatfda_docs/label/2025/212436s008lbl.pdf',
       'Drug label', 'palbociclib', 'Second official source for the same drug'),
      ('208716s017lbl.pdf',
       'Verzenio (abemaciclib) Prescribing Information', 'US FDA',
       'https://www.accessdata.fda.gov/drugsatfda_docs/label/2024/208716s017lbl.pdf',
       'Drug label', 'abemaciclib', 'Second official source for the same drug'),
      ('pharmac_palbociclib_decision_2020.txt',
       'Decision to fund palbociclib (Ibrance) for advanced breast cancer', 'Pharmac',
       'https://www.pharmac.govt.nz/news-and-resources/consultations-and-decisions/decision-to-fund-palbociclib-ibrance-for-advanced-breast-cancer',
       'Web page (text)', NULL, 'NZ funding context'),
      ('pharmac_ribociclib_decision_2024.txt',
       'Decision to fund treatments for breast cancer and leukaemia', 'Pharmac',
       'https://www.pharmac.govt.nz/news-and-resources/consultations-and-decisions/decision-to-fund-treatments-for-breast-cancer-and-leukaemia',
       'Web page (text)', 'multiple', 'Mentions grade 3-4 reactions without numbers; tests gap handling'),
      ('2025-11-20-Cancer-Treatments-Advisory-Committee-Record.pdf',
       'Record of the Cancer Treatments Advisory Committee, 20 November 2025', 'Pharmac',
       'https://www.pharmac.govt.nz/assets/2025-11-20-Cancer-Treatments-Advisory-Committee-Record.pdf',
       'Committee record', 'multiple', 'NZ funding committee discussion')
    AS v(file_name, title, publisher, source_url, doc_type, primary_drug, why_chosen)
) s
ON t.file_name = s.file_name
WHEN NOT MATCHED THEN INSERT
    (file_name, title, publisher, source_url, doc_type, primary_drug, downloaded_on, why_chosen)
VALUES
    (s.file_name, s.title, s.publisher, s.source_url, s.doc_type, s.primary_drug, CURRENT_DATE(), s.why_chosen);

-- ---------------------------------------------------------------------
-- 2. Cards from source_manifest.json
--    Works whether the manifest is a list, or an object holding a list
--    under "sources", "files", "documents" or "items".
-- ---------------------------------------------------------------------
MERGE INTO SOURCE_REGISTER t
USING (
    WITH raw AS (
        SELECT $1 AS v
        FROM @DOCS_STAGE/source_manifest.json (FILE_FORMAT => 'JSON_FF')
    ),
    items AS (
        SELECT f.value AS item
        FROM raw,
             LATERAL FLATTEN(input => COALESCE(v:sources, v:files, v:documents, v:items, ARRAY_CONSTRUCT(v))) f
    ),
    cards AS (
        SELECT
            REGEXP_SUBSTR(
                COALESCE(item:file_name, item:filename, item:file, item:local_file, item:path)::STRING,
                '[^/]+$')                                                                   AS file_name,
            COALESCE(item:title, item:name)::STRING                                         AS title,
            COALESCE(item:publisher, item:source, item:organisation, item:organization)::STRING AS publisher,
            COALESCE(item:source_url, item:url, item:link)::STRING                           AS source_url,
            COALESCE(item:doc_type, item:type, 'Document')::STRING                           AS doc_type,
            COALESCE(item:primary_drug, item:drug)::STRING                                   AS primary_drug,
            COALESCE(item:why_chosen, item:reason, item:notes,
                     'Listed in source_manifest.json')::STRING                               AS why_chosen
        FROM items
    )
    SELECT *
    FROM cards
    WHERE file_name IS NOT NULL
    QUALIFY ROW_NUMBER() OVER (PARTITION BY file_name ORDER BY title) = 1     -- one card per file
) s
ON t.file_name = s.file_name
WHEN NOT MATCHED THEN INSERT
    (file_name, title, publisher, source_url, doc_type, primary_drug, downloaded_on, why_chosen)
VALUES
    (s.file_name, s.title, s.publisher, s.source_url, s.doc_type, s.primary_drug, CURRENT_DATE(), s.why_chosen);

-- ---------------------------------------------------------------------
-- 3. Results
-- ---------------------------------------------------------------------

-- All cards
SELECT file_name, publisher, primary_drug, LEFT(source_url, 70) AS source_url
FROM SOURCE_REGISTER
ORDER BY file_name;

-- Files in the stage that still have NO card.
-- Each row is a ready-to-fill line: copy them into the INSERT at the bottom of this file.
SELECT '(''' || REPLACE(RELATIVE_PATH, '''', '''''')
       || ''', ''TITLE'', ''PUBLISHER'', ''SOURCE_URL'', ''Document'', NULL, CURRENT_DATE(), ''WHY CHOSEN''),'
       AS fill_me_in
FROM DIRECTORY(@DOCS_STAGE)
WHERE RELATIVE_PATH ILIKE ANY ('%.pdf', '%.txt', '%.md', '%.json')
  AND RELATIVE_PATH NOT ILIKE 'source_manifest.json'
  AND RELATIVE_PATH NOT ILIKE 'README%'
  AND RELATIVE_PATH NOT IN (SELECT file_name FROM SOURCE_REGISTER)
UNION ALL
SELECT '(''' || REPLACE(RELATIVE_PATH, '''', '''''')
       || ''', ''TITLE'', ''PUBLISHER'', ''SOURCE_URL'', ''Image'', NULL, CURRENT_DATE(), ''WHY CHOSEN''),'
FROM DIRECTORY(@IMAGES_STAGE)
WHERE RELATIVE_PATH ILIKE ANY ('%.png', '%.jpg', '%.jpeg', '%.webp')
  AND RELATIVE_PATH NOT IN (SELECT file_name FROM SOURCE_REGISTER);

-- ---------------------------------------------------------------------
-- 4. (Only if step 3 listed files) Paste the lines below, fill in the
--    real title, publisher and URL, change the last comma to ;
--    then select just this statement and run it.
--    Never make up a URL: if a file has no public source, leave it out.
-- ---------------------------------------------------------------------
-- INSERT INTO SOURCE_REGISTER
--   (file_name, title, publisher, source_url, doc_type, primary_drug, downloaded_on, why_chosen)
-- VALUES
--   ('example.pdf', 'Title', 'Publisher', 'https://...', 'Document', NULL, CURRENT_DATE(), 'Why chosen');