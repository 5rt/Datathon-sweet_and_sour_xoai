USE ROLE EVIDENCE_DEV;
USE WAREHOUSE EVIDENCE_WH;
USE SCHEMA EVIDENCE_DB.CORE;

-- Old file names from the first build
UPDATE GOLD_LABELS SET file_name = 'Kisqalitab.pdf' WHERE file_name = 'ribociclib_datasheet.pdf';

-- Add answers you read yourselves (replace with YOUR numbers), e.g.:
-- INSERT INTO GOLD_LABELS (file_name, drug, outcome, grade, value, labelled_by, note) VALUES
--   ('Kisqalitab.pdf', 'ribociclib', 'diarrhoea', 'Any grade', 23, 'Your name', 'Table, page 23');

WITH scope AS (SELECT DISTINCT file_name, drug, outcome FROM GOLD_LABELS),
found AS (
    SELECT DISTINCT 'Rule A: sentences only' AS rule_set, e.drug, e.outcome, e.grade, e.pct_value, e.file_name
    FROM SENTENCE_EVIDENCE e JOIN scope s USING (file_name, drug, outcome)
    WHERE e.pct_value IS NOT NULL
    UNION ALL
    SELECT DISTINCT 'Rule B: sentences + tables', e.drug, e.outcome, e.grade, e.pct_value, e.file_name
    FROM EVIDENCE e JOIN scope s USING (file_name, drug, outcome)
    WHERE e.pct_value IS NOT NULL
),
matched AS (
    SELECT f.*, g.gold_id
    FROM found f
    LEFT JOIN GOLD_LABELS g
      ON g.file_name = f.file_name AND g.drug = f.drug AND g.outcome = f.outcome
     AND g.grade = f.grade AND ABS(g.value - f.pct_value) <= 0.5
)
SELECT r.rule_set,
       (SELECT COUNT(*) FROM GOLD_LABELS)                                               AS gold_answers,
       COUNT(DISTINCT m.drug || m.outcome || m.grade || m.pct_value || m.file_name)     AS numbers_extracted,
       COUNT(DISTINCT m.gold_id)                                                        AS gold_found,
       ROUND(100 * COUNT(DISTINCT IFF(m.gold_id IS NOT NULL,
             m.drug || m.outcome || m.grade || m.pct_value || m.file_name, NULL))
             / NULLIF(COUNT(DISTINCT m.drug || m.outcome || m.grade || m.pct_value || m.file_name), 0), 1) AS precision_pct,
       ROUND(100 * COUNT(DISTINCT m.gold_id) / NULLIF((SELECT COUNT(*) FROM GOLD_LABELS), 0), 1)       AS recall_pct
FROM (SELECT 'Rule A: sentences only' AS rule_set UNION ALL SELECT 'Rule B: sentences + tables') r
LEFT JOIN matched m ON m.rule_set = r.rule_set
GROUP BY r.rule_set
ORDER BY r.rule_set;