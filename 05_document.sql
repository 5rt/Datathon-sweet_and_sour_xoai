USE ROLE EVIDENCE_DEV;
USE WAREHOUSE EVIDENCE_WH;
USE SCHEMA EVIDENCE_DB.CORE;

ALTER STAGE DOCS_STAGE REFRESH;
ALTER STAGE IMAGES_STAGE REFRESH;

-- Physical list of files + fingerprints (the app adds rows here on upload)
CREATE OR REPLACE TABLE STAGE_FILES (
    file_name        STRING,
    source_stage     STRING,          -- DOCS or IMAGES
    file_md5         STRING,
    file_size_bytes  NUMBER,
    uploaded_at      TIMESTAMP_TZ
);

INSERT INTO STAGE_FILES
SELECT RELATIVE_PATH, 'DOCS', MD5, SIZE, LAST_MODIFIED
FROM DIRECTORY(@DOCS_STAGE)
WHERE RELATIVE_PATH ILIKE ANY ('%.pdf', '%.txt', '%.md', '%.json')
  AND RELATIVE_PATH NOT ILIKE 'source_manifest.json'     -- list of sources, not evidence
  AND RELATIVE_PATH NOT ILIKE 'README%'                   -- project notes, not evidence
UNION ALL
SELECT RELATIVE_PATH, 'IMAGES', MD5, SIZE, LAST_MODIFIED
FROM DIRECTORY(@IMAGES_STAGE)
WHERE RELATIVE_PATH ILIKE ANY ('%.png', '%.jpg', '%.jpeg', '%.webp');

-- Files + library cards + main drug (worked out live from the vocabulary)
CREATE OR REPLACE VIEW DOCUMENTS AS
WITH guessed AS (
    SELECT f.file_name, t.drug
    FROM STAGE_FILES f
    LEFT JOIN SOURCE_REGISTER r ON r.file_name = f.file_name
    JOIN DRUG_TERMS t ON (f.file_name || ' ' || COALESCE(r.title, '')) ILIKE '%' || t.term || '%'
    QUALIFY ROW_NUMBER() OVER (PARTITION BY f.file_name ORDER BY LENGTH(t.term) DESC) = 1
),
known AS (SELECT DISTINCT drug FROM DRUG_TERMS)
SELECT
    f.file_name, f.source_stage, f.file_md5, f.file_size_bytes, f.uploaded_at,
    r.title, r.publisher, r.source_url, r.doc_type,
    CASE WHEN r.primary_drug = 'multiple' OR k.drug IS NOT NULL THEN r.primary_drug
         ELSE COALESCE(g.drug, 'multiple') END AS primary_drug
FROM STAGE_FILES f
LEFT JOIN SOURCE_REGISTER r ON r.file_name = f.file_name
LEFT JOIN known k           ON k.drug = r.primary_drug
LEFT JOIN guessed g         ON g.file_name = f.file_name;

SELECT source_stage, file_name, publisher, primary_drug FROM DOCUMENTS ORDER BY source_stage, file_name;

-- Safety check: must return NO rows (go back to 04 step 3 if it does)
SELECT file_name AS missing_library_card FROM DOCUMENTS WHERE source_url IS NULL;