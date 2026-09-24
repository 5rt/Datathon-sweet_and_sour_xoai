USE ROLE EVIDENCE_DEV;
USE WAREHOUSE EVIDENCE_WH;
USE SCHEMA EVIDENCE_DB.CORE;

SELECT 'files without a library card' AS test, COUNT(*) AS failures
FROM DOCUMENTS WHERE source_url IS NULL
UNION ALL
SELECT 'files flagged with personal info', COUNT(*)
FROM SOURCE_REGISTER WHERE contains_personal_info
UNION ALL
SELECT 'duplicate library cards', COUNT(*) - COUNT(DISTINCT file_name)
FROM SOURCE_REGISTER
UNION ALL
SELECT 'documents with no pages read', COUNT(*)
FROM DOCUMENTS d LEFT JOIN (SELECT DISTINCT file_name FROM DOC_PAGES) p ON p.file_name = d.file_name
WHERE d.source_stage = 'DOCS' AND p.file_name IS NULL
UNION ALL
SELECT 'statements using an unapproved drug', COUNT(*)
FROM HYPOTHESES
WHERE drug_a NOT IN (SELECT drug FROM DRUG_TERMS) OR drug_b NOT IN (SELECT drug FROM DRUG_TERMS)
UNION ALL
SELECT 'statements using an unapproved side effect', COUNT(*)
FROM HYPOTHESES WHERE outcome NOT IN (SELECT outcome FROM OUTCOME_TERMS)
UNION ALL
SELECT 'drugs outside breast cancer scope', COUNT(*)
FROM DRUG_TERMS WHERE cancer_type IS DISTINCT FROM 'Breast cancer'
UNION ALL
SELECT 'OCR rows without a quality label', COUNT(*)
FROM OCR_RESULTS WHERE quality_label IS NULL
UNION ALL
SELECT 'OCR on unregistered images', COUNT(*)
FROM OCR_RESULTS o LEFT JOIN DOCUMENTS d ON d.file_name = o.file_name
WHERE d.source_url IS NULL;