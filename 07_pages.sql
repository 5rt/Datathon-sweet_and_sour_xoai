USE ROLE EVIDENCE_DEV;
USE WAREHOUSE EVIDENCE_WH;
USE SCHEMA EVIDENCE_DB.CORE;

-- 1. Pages
CREATE OR REPLACE TABLE DOC_PAGES AS
SELECT d.file_name, p.page_no, p.page_text
FROM DOCUMENTS d,
     TABLE(READ_DOC(BUILD_SCOPED_FILE_URL(@DOCS_STAGE, d.file_name), d.file_name)) p
WHERE d.source_stage = 'DOCS';

-- 2. Sentences, each with a traceable name tag
CREATE OR REPLACE TABLE SNIPPETS AS
SELECT p.file_name || '|p' || p.page_no || '|s' || s.index AS snippet_id,
       p.file_name, p.page_no, s.index AS snippet_no, TRIM(s.value) AS snippet
FROM DOC_PAGES p,
     LATERAL SPLIT_TO_TABLE(REGEXP_REPLACE(p.page_text, '[[:space:]]+', ' '), '. ') s
WHERE LENGTH(TRIM(s.value)) > 20;

-- 3. OCR every registered image that hasn't been read yet
INSERT INTO OCR_RESULTS
WITH waiting AS (
    SELECT file_name FROM DOCUMENTS
    WHERE source_stage = 'IMAGES' AND source_url IS NOT NULL
      AND file_name NOT IN (SELECT file_name FROM OCR_RESULTS)
),
lines AS (
    SELECT w.file_name, o.line_no, o.text, o.confidence
    FROM waiting w, TABLE(OCR_IMAGE(BUILD_SCOPED_FILE_URL(@IMAGES_STAGE, w.file_name))) o
),
stats AS (SELECT file_name, AVG(confidence) AS avg_conf FROM lines GROUP BY file_name)
SELECT l.file_name, l.line_no, l.text, l.confidence, s.avg_conf,
       CASE WHEN s.avg_conf >= 0.90 THEN 'Good'
            WHEN s.avg_conf >= 0.75 THEN 'Acceptable'
            WHEN s.avg_conf >= 0.50 THEN 'Poor'
            ELSE 'Unusable' END,
       'RapidOCR (Snowflake function)', CURRENT_TIMESTAMP()
FROM lines l JOIN stats s ON s.file_name = l.file_name;

SELECT 'pages' AS what, COUNT(*) AS n FROM DOC_PAGES
UNION ALL SELECT 'sentences', COUNT(*) FROM SNIPPETS
UNION ALL SELECT 'images read', COUNT(DISTINCT file_name) FROM OCR_RESULTS;