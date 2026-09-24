USE ROLE EVIDENCE_DEV;
USE WAREHOUSE EVIDENCE_WH;
USE SCHEMA EVIDENCE_DB.CORE;

-- ============ Shared building blocks ============

-- Each statement split into side A and side B
CREATE OR REPLACE VIEW HYPOTHESIS_SIDES AS
SELECT hypothesis_id, 'A' AS side, drug_a AS drug, outcome FROM HYPOTHESES
UNION ALL
SELECT hypothesis_id, 'B' AS side, drug_b AS drug, outcome FROM HYPOTHESES;

-- All OCR text of one image as one string
CREATE OR REPLACE VIEW IMAGE_TEXT AS
SELECT file_name,
       MAX(quality_label)              AS quality_label,
       ROUND(MAX(file_confidence), 2)  AS avg_confidence,
       COUNT(ocr_text)                 AS lines_found,
       REGEXP_REPLACE(LISTAGG(ocr_text, ' ') WITHIN GROUP (ORDER BY line_no), '[[:space:]]+', ' ') AS txt
FROM OCR_RESULTS
GROUP BY file_name;

-- Readable text: document pages + good-quality images
CREATE OR REPLACE VIEW PAGE_TEXT AS
SELECT p.file_name, p.page_no, d.primary_drug, 'table' AS kind,
       REGEXP_REPLACE(p.page_text, '[[:space:]]+', ' ') AS txt
FROM DOC_PAGES p JOIN DOCUMENTS d ON d.file_name = p.file_name
UNION ALL
SELECT i.file_name, 1, d.primary_drug, 'ocr', i.txt
FROM IMAGE_TEXT i JOIN DOCUMENTS d ON d.file_name = i.file_name
WHERE i.quality_label IN ('Good', 'Acceptable');

-- Sentence-sized pieces: document sentences + good-quality OCR lines
CREATE OR REPLACE VIEW ALL_SNIPPETS AS
SELECT snippet_id, file_name, page_no, snippet, 'text' AS source_kind FROM SNIPPETS
UNION ALL
SELECT file_name || '|ocr|l' || line_no, file_name, 1, ocr_text, 'ocr'
FROM OCR_RESULTS
WHERE quality_label IN ('Good', 'Acceptable') AND ocr_text IS NOT NULL;

-- One table-row pattern per side-effect word: "<term> <all grades> <grade 3> <grade 4>"
CREATE OR REPLACE VIEW TABLE_ROW_PATTERNS AS
SELECT outcome, term,
       term || '[0-9]{0,1} {0,1}(<{0,1} {0,1}[0-9]+[.]{0,1}[0-9]*) (<{0,1} {0,1}[0-9]+[.]{0,1}[0-9]*) (<{0,1} {0,1}[0-9]+[.]{0,1}[0-9]*)' AS rx
FROM OUTCOME_TERMS;

-- Every adverse-reaction table row found (first 3 numbers = drug arm; placebo ignored)
CREATE OR REPLACE VIEW TABLE_FACTS AS
WITH found AS (
    SELECT pg.primary_drug AS drug, pt.outcome, pt.term, pg.file_name, pg.page_no, pg.kind,
           REGEXP_SUBSTR(pg.txt, pt.rx, 1, 1, 'i')     AS row_text,
           REGEXP_SUBSTR(pg.txt, pt.rx, 1, 1, 'ie', 1) AS all_txt,
           REGEXP_SUBSTR(pg.txt, pt.rx, 1, 1, 'ie', 2) AS g3_txt,
           REGEXP_SUBSTR(pg.txt, pt.rx, 1, 1, 'ie', 3) AS g4_txt
    FROM PAGE_TEXT pg
    JOIN TABLE_ROW_PATTERNS pt ON pg.txt ILIKE '%' || pt.term || '%'
)
SELECT drug, outcome, term, file_name, page_no, kind, row_text, all_txt, g3_txt, g4_txt,
       TRY_TO_DOUBLE(REGEXP_REPLACE(all_txt, '[< ]', ''))                    AS all_grade,
       TRY_TO_DOUBLE(REGEXP_REPLACE(g3_txt, '[< ]', ''))
         + TRY_TO_DOUBLE(REGEXP_REPLACE(g4_txt, '[< ]', ''))                 AS grade3_4
FROM found
WHERE row_text IS NOT NULL;

-- ============ Evidence for statements ============

-- Sentences mentioning the side effect, for the drug (named in the sentence, or the file's main drug)
CREATE OR REPLACE VIEW SENTENCE_EVIDENCE AS
SELECT DISTINCT
    h.hypothesis_id, h.side, h.drug, h.outcome,
    s.snippet_id, s.file_name, s.page_no, s.snippet,
    IFF(s.source_kind = 'ocr', 'ocr', 'sentence') AS evidence_type,
    TRY_TO_DOUBLE(REGEXP_SUBSTR(s.snippet, '([0-9]+[.]{0,1}[0-9]*) {0,1}%', 1, 1, 'e', 1)) AS pct_value,
    CASE WHEN s.snippet ILIKE ANY ('%grade 3%', '%grade 4%', '%grade 3/4%', '%grade 3-4%') THEN 'Grade 3-4'
         WHEN s.snippet ILIKE ANY ('%all grade%', '%any grade%')                         THEN 'Any grade'
         ELSE 'Not stated' END AS grade
FROM HYPOTHESIS_SIDES h
JOIN OUTCOME_TERMS o ON o.outcome = h.outcome
JOIN ALL_SNIPPETS s  ON s.snippet ILIKE '%' || o.term || '%'
JOIN DOCUMENTS d     ON d.file_name = s.file_name
LEFT JOIN DRUG_TERMS t ON t.drug = h.drug AND s.snippet ILIKE '%' || t.term || '%'
WHERE (t.term IS NOT NULL OR d.primary_drug = h.drug)
  AND LENGTH(s.snippet) <= 400;                 -- longer pieces are squashed tables, read by TABLE_FACTS

-- Table rows for the statement's drug and side effect: one row for any grade, one for grade 3-4
CREATE OR REPLACE VIEW TABLE_EVIDENCE AS
SELECT h.hypothesis_id, h.side, h.drug, h.outcome,
       t.file_name || '|p' || t.page_no || '|' || t.kind || '|any' AS snippet_id,
       t.file_name, t.page_no,
       'Table row: ' || t.row_text || ' (drug arm, all grades: ' || t.all_txt || '%)' AS snippet,
       t.kind AS evidence_type, t.all_grade AS pct_value, 'Any grade' AS grade
FROM HYPOTHESIS_SIDES h
JOIN TABLE_FACTS t ON t.drug = h.drug AND t.outcome = h.outcome
WHERE t.all_grade IS NOT NULL
UNION ALL
SELECT h.hypothesis_id, h.side, h.drug, h.outcome,
       t.file_name || '|p' || t.page_no || '|' || t.kind || '|g34',
       t.file_name, t.page_no,
       'Table row: ' || t.row_text || ' (drug arm: grade 3 ' || t.g3_txt || '% + grade 4 ' || t.g4_txt || '%)',
       t.kind, t.grade3_4, 'Grade 3-4'
FROM HYPOTHESIS_SIDES h
JOIN TABLE_FACTS t ON t.drug = h.drug AND t.outcome = h.outcome
WHERE t.grade3_4 IS NOT NULL;

-- All evidence, with source details and a status
CREATE OR REPLACE VIEW EVIDENCE AS
WITH all_rows AS (
    SELECT * FROM SENTENCE_EVIDENCE
    UNION ALL
    SELECT * FROM TABLE_EVIDENCE
)
SELECT e.*, d.title, d.publisher, d.source_url,
       COALESCE(REGEXP_SUBSTR(e.snippet, '[A-Z]{4,}[- ]{0,1}[0-9]{1,2}'), 'Not stated') AS study_id,
       CASE WHEN e.evidence_type = 'ocr' THEN 'Needs review'     -- image evidence is always human-checked
            WHEN e.pct_value IS NULL      THEN 'Mention only'
            WHEN e.snippet LIKE '%<%'     THEN 'Needs review'     -- values like "<1"
            ELSE 'Has number' END AS extract_status
FROM all_rows e
JOIN DOCUMENTS d ON d.file_name = e.file_name;

-- Every Drug A number paired with every Drug B number, labelled
CREATE OR REPLACE VIEW COMPARISONS AS
WITH pairs AS (
    SELECT a.hypothesis_id, h.direction,
           a.drug AS drug_a, a.pct_value AS a_pct, a.grade AS a_grade, a.study_id AS a_study,
           a.file_name AS a_file, a.page_no AS a_page, a.snippet_id AS a_snippet_id,
           b.drug AS drug_b, b.pct_value AS b_pct, b.grade AS b_grade, b.study_id AS b_study,
           b.file_name AS b_file, b.page_no AS b_page, b.snippet_id AS b_snippet_id,
           (a.grade = 'Not stated' OR a.grade <> b.grade) AS grade_differs,
           (a.file_name <> b.file_name AND (a.study_id = 'Not stated' OR a.study_id <> b.study_id)) AS source_differs
    FROM EVIDENCE a
    JOIN EVIDENCE b   ON b.hypothesis_id = a.hypothesis_id AND a.side = 'A' AND b.side = 'B'
    JOIN HYPOTHESES h ON h.hypothesis_id = a.hypothesis_id
    WHERE a.pct_value IS NOT NULL AND b.pct_value IS NOT NULL
)
SELECT pairs.* EXCLUDE (direction, grade_differs, source_differs),
       CASE WHEN grade_differs OR source_differs THEN 'Not comparable'
            WHEN (direction = 'lower' AND a_pct < b_pct) OR (direction = 'higher' AND a_pct > b_pct) THEN 'Supports'
            ELSE 'Limits' END AS evidence_label,
       CASE WHEN grade_differs  THEN 'Different or unstated severity grade'
            WHEN source_differs THEN 'Numbers come from different sources/trials (not head-to-head)'
            ELSE 'Same source and same grade' END AS reason
FROM pairs;

-- Verdict + plain-English summary (rule-generated, not AI)
CREATE OR REPLACE VIEW HYPOTHESIS_SUMMARY AS
WITH ev AS (
    SELECT hypothesis_id,
           COUNT_IF(side = 'A') AS a_evidence,
           COUNT_IF(side = 'B') AS b_evidence,
           COUNT_IF(extract_status <> 'Has number') AS needs_review
    FROM EVIDENCE GROUP BY hypothesis_id
),
c AS (
    SELECT hypothesis_id,
           COUNT_IF(evidence_label = 'Supports')       AS supports,
           COUNT_IF(evidence_label = 'Limits')         AS limits,
           COUNT_IF(evidence_label = 'Not comparable') AS not_comparable
    FROM COMPARISONS GROUP BY hypothesis_id
),
base AS (
    SELECT h.hypothesis_id, h.hypothesis_text, h.drug_a, h.drug_b, h.outcome,
           COALESCE(ev.a_evidence, 0)    AS a_evidence,
           COALESCE(ev.b_evidence, 0)    AS b_evidence,
           COALESCE(ev.needs_review, 0)  AS needs_review,
           COALESCE(c.supports, 0)       AS supports,
           COALESCE(c.limits, 0)         AS limits,
           COALESCE(c.not_comparable, 0) AS not_comparable
    FROM HYPOTHESES h
    LEFT JOIN ev ON ev.hypothesis_id = h.hypothesis_id
    LEFT JOIN c  ON c.hypothesis_id  = h.hypothesis_id
)
SELECT base.*,
       CASE WHEN a_evidence = 0 OR b_evidence = 0 THEN 'Evidence gap: nothing found for one of the drugs'
            WHEN supports = 0 AND limits = 0      THEN 'Not sufficient: no like-for-like comparison found'
            WHEN limits = 0                       THEN 'Some like-for-like support: needs human review'
            WHEN supports = 0                     THEN 'Like-for-like evidence does not support it: needs human review'
            ELSE 'Mixed evidence: needs human review' END AS verdict,
       'Found ' || a_evidence || ' evidence rows for ' || drug_a || ' and ' || b_evidence || ' for ' || drug_b || '. '
       || 'Like-for-like pairs: ' || supports || ' support the statement and ' || limits || ' do not. '
       || not_comparable || ' pairs are not comparable (different sources, trials or severity grades). '
       || needs_review || ' evidence rows need human review. (Rule-generated summary, not AI.)' AS summary_text
FROM base;

-- ============ Image analysis ============

-- Structured facts per image + side effect, cross-checked against the text PDFs
CREATE OR REPLACE VIEW IMAGE_FACTS AS
WITH found AS (
    SELECT i.file_name, i.quality_label, i.avg_confidence, d.primary_drug AS drug, p.outcome, p.term,
           REGEXP_SUBSTR(i.txt, p.rx, 1, 1, 'i') AS row_text,
           TRY_TO_DOUBLE(REGEXP_REPLACE(REGEXP_SUBSTR(i.txt, p.rx, 1, 1, 'ie', 1), '[< ]', '')) AS all_grade,
           TRY_TO_DOUBLE(REGEXP_REPLACE(REGEXP_SUBSTR(i.txt, p.rx, 1, 1, 'ie', 2), '[< ]', ''))
             + TRY_TO_DOUBLE(REGEXP_REPLACE(REGEXP_SUBSTR(i.txt, p.rx, 1, 1, 'ie', 3), '[< ]', '')) AS grade3_4,
           TRY_TO_DOUBLE(REGEXP_SUBSTR(i.txt, p.term || '[^%]{0,40} ([0-9]+[.]{0,1}[0-9]*) {0,1}%', 1, 1, 'ie', 1)) AS pct_nearby
    FROM IMAGE_TEXT i
    JOIN DOCUMENTS d ON d.file_name = i.file_name
    JOIN TABLE_ROW_PATTERNS p ON i.txt ILIKE '%' || p.term || '%'
    QUALIFY ROW_NUMBER() OVER (PARTITION BY i.file_name, p.outcome ORDER BY IFF(row_text IS NULL, 1, 0), p.term) = 1
),
pdf AS (
    SELECT drug, outcome, MIN(all_grade) AS pdf_min, MAX(all_grade) AS pdf_max
    FROM TABLE_FACTS WHERE kind = 'table' AND all_grade IS NOT NULL
    GROUP BY drug, outcome
)
SELECT f.file_name, f.drug, f.outcome,
       CASE WHEN f.row_text IS NOT NULL THEN 'Table row'
            WHEN f.pct_nearby IS NOT NULL THEN 'Text with %'
            ELSE 'Mention only' END                                 AS fact_type,
       COALESCE(f.all_grade, f.pct_nearby)                          AS any_grade_pct,
       f.grade3_4                                                   AS grade3_4_pct,
       p.pdf_min                                                    AS pdf_any_grade_pct,
       CASE WHEN p.pdf_min IS NULL OR COALESCE(f.all_grade, f.pct_nearby) IS NULL THEN 'No PDF value to compare'
            WHEN COALESCE(f.all_grade, f.pct_nearby) BETWEEN p.pdf_min - 0.5 AND p.pdf_max + 0.5 THEN 'Matches PDF'
            ELSE 'Differs from PDF' END                             AS cross_check,
       CASE WHEN f.quality_label IN ('Poor', 'Unusable') THEN 'Excluded: low image quality'
            WHEN COALESCE(f.all_grade, f.pct_nearby) IS NULL THEN 'Mention only'
            ELSE 'Needs review' END                                 AS status,
       COALESCE(f.row_text, 'Mentions ' || f.term)                  AS evidence_text,
       f.quality_label, f.avg_confidence
FROM found f
LEFT JOIN pdf p ON p.drug = f.drug AND p.outcome = f.outcome;

-- One profile per image, with a plain-English summary
CREATE OR REPLACE VIEW IMAGE_PROFILE AS
WITH drugs AS (
    SELECT i.file_name, LISTAGG(DISTINCT t.drug, ', ') WITHIN GROUP (ORDER BY t.drug) AS drugs_detected
    FROM IMAGE_TEXT i JOIN DRUG_TERMS t ON i.txt ILIKE '%' || t.term || '%'
    GROUP BY i.file_name
),
facts AS (
    SELECT file_name,
           COUNT(*)                                   AS outcomes_found,
           COUNT_IF(fact_type = 'Table row')          AS table_rows,
           COUNT_IF(cross_check = 'Matches PDF')      AS matches_pdf,
           COUNT_IF(cross_check = 'Differs from PDF') AS differs_pdf
    FROM IMAGE_FACTS GROUP BY file_name
)
SELECT i.file_name, d.title, d.publisher, d.source_url,
       d.primary_drug                                   AS registered_drug,
       COALESCE(dr.drugs_detected, 'None')              AS drugs_detected,
       CASE WHEN dr.drugs_detected IS NULL THEN 'No drug name found in image'
            WHEN d.primary_drug = 'multiple' OR CONTAINS(dr.drugs_detected, d.primary_drug) THEN 'Matches library card'
            ELSE 'Check: image mentions a different drug' END AS drug_check,
       CASE WHEN i.txt ILIKE '%data sheet%'              THEN 'Data sheet'
            WHEN i.txt ILIKE '%prescribing information%' THEN 'Drug label'
            WHEN i.txt ILIKE '%pharmac%'                 THEN 'Funding decision'
            WHEN i.txt ILIKE ANY ('%adverse%', '%grade%') THEN 'Side-effect table'
            ELSE 'Unknown' END                          AS content_type,
       COALESCE(REGEXP_SUBSTR(i.txt, '[A-Z]{4,}[- ]{0,1}[0-9]{1,2}'), 'Not stated') AS trial_mentioned,
       i.lines_found, i.avg_confidence, i.quality_label,
       COALESCE(f.outcomes_found, 0) AS outcomes_found,
       COALESCE(f.table_rows, 0)     AS table_rows,
       COALESCE(f.matches_pdf, 0)    AS matches_pdf,
       COALESCE(f.differs_pdf, 0)    AS differs_pdf,
       'Image quality: ' || i.quality_label || ' (confidence ' || COALESCE(TO_VARCHAR(i.avg_confidence), 'n/a') || '). '
       || 'Drugs detected: ' || COALESCE(dr.drugs_detected, 'none') || '. '
       || COALESCE(f.outcomes_found, 0) || ' side effects found, ' || COALESCE(f.table_rows, 0) || ' from table rows. '
       || COALESCE(f.matches_pdf, 0) || ' match the official PDF and ' || COALESCE(f.differs_pdf, 0) || ' differ. '
       || IFF(i.quality_label IN ('Poor', 'Unusable'),
              'Excluded from evidence because of low image quality. ',
              'Used as evidence, marked Needs review. ')
       || '(Rule-generated summary, not AI.)'          AS summary_text
FROM IMAGE_TEXT i
LEFT JOIN DOCUMENTS d ON d.file_name = i.file_name
LEFT JOIN drugs dr    ON dr.file_name = i.file_name
LEFT JOIN facts f     ON f.file_name = i.file_name;

-- ============ Discovery (a human approves these in the app) ============

-- Drug names found by their international name endings
CREATE OR REPLACE VIEW DRUG_CANDIDATES AS
WITH hits AS (
    SELECT p.file_name, LOWER(f.value::STRING) AS drug
    FROM DOC_PAGES p,
         LATERAL FLATTEN(input => REGEXP_SUBSTR_ALL(p.page_text,
             '[A-Za-z]*(ciclib|tuzumab|zumab|ximab|mumab|taxel|tinib|platin|rubicin|parib|lisib)( [a-z]*(tansine|tecan|dotin)){0,1}',
             1, 1, 'i')) f
)
SELECT h.drug,
       CASE WHEN h.drug LIKE '%ciclib'   THEN 'CDK4/6 inhibitor'
            WHEN h.drug LIKE '%tuzumab%' THEN 'Anti-HER2 therapy'
            WHEN h.drug LIKE '%taxel'    THEN 'Taxane'
            WHEN h.drug LIKE '%tinib'    THEN 'Kinase inhibitor'
            WHEN h.drug LIKE '%platin'   THEN 'Platinum chemotherapy'
            WHEN h.drug LIKE '%rubicin'  THEN 'Anthracycline'
            WHEN h.drug LIKE '%parib'    THEN 'PARP inhibitor'
            WHEN h.drug LIKE '%lisib'    THEN 'PI3K inhibitor'
            ELSE 'Monoclonal antibody' END              AS suggested_class,
       COUNT(*)                                          AS mentions,
       COUNT(DISTINCT h.file_name)                       AS documents,
       IFF(MAX(k.drug) IS NULL, 'New', 'Approved')       AS status
FROM hits h
LEFT JOIN (SELECT DISTINCT drug FROM DRUG_TERMS) k ON k.drug = h.drug
GROUP BY h.drug
HAVING COUNT(*) >= 3;                                    -- ignore one-off mentions

-- Brand names from labels written like "KADCYLA® (ado-trastuzumab emtansine)"
CREATE OR REPLACE VIEW BRAND_CANDIDATES AS
WITH pairs AS (
    SELECT DISTINCT p.file_name,
           LOWER(REGEXP_SUBSTR(f.value::STRING, '^[A-Z-]+'))                  AS brand,
           LOWER(REGEXP_SUBSTR(f.value::STRING, '\\(([^)]+)\\)', 1, 1, 'e', 1)) AS generic_text
    FROM DOC_PAGES p,
         LATERAL FLATTEN(input => REGEXP_SUBSTR_ALL(p.page_text, '[A-Z][A-Z-]{2,}® {0,1}\\([A-Za-z -]+\\)')) f
),
matched AS (
    SELECT pr.file_name, pr.brand, pr.generic_text, t.drug
    FROM pairs pr
    JOIN (SELECT DISTINCT drug FROM DRUG_TERMS) t ON pr.generic_text ILIKE '%' || t.drug || '%'
    WHERE pr.brand <> t.drug
    QUALIFY ROW_NUMBER() OVER (PARTITION BY pr.brand ORDER BY LENGTH(t.drug) DESC) = 1
)
SELECT m.brand, m.drug, m.generic_text, m.file_name,
       IFF(k.term IS NULL, 'New', 'Approved') AS status
FROM matched m
LEFT JOIN (SELECT DISTINCT term FROM DRUG_TERMS) k ON k.term = m.brand;

-- Side effects from adverse-reaction table rows like "Diarrhoea 23 2 0"
CREATE OR REPLACE VIEW OUTCOME_CANDIDATES AS
WITH rows_found AS (
    SELECT p.file_name, LOWER(TRIM(f.value::STRING)) AS term
    FROM DOC_PAGES p,
         LATERAL FLATTEN(input => REGEXP_SUBSTR_ALL(
             REGEXP_REPLACE(p.page_text, '[[:space:]]+', ' '),
             '([A-Z][a-z]{3,}( [a-z]{2,}){0,3}) [0-9<]{1,4} [0-9<]{1,4} [0-9<]{1,4}',
             1, 1, 'e', 1)) f
    WHERE p.page_text ILIKE '%adverse%'
)
SELECT r.term,
       COUNT(*)                                    AS mentions,
       COUNT(DISTINCT r.file_name)                 AS documents,
       IFF(MAX(k.term) IS NULL, 'New', 'Approved') AS status
FROM rows_found r
LEFT JOIN (SELECT DISTINCT term FROM OUTCOME_TERMS) k ON r.term ILIKE '%' || k.term || '%'
WHERE LENGTH(r.term) BETWEEN 4 AND 40
  AND r.term NOT IN ('grade', 'table', 'total', 'placebo', 'patients', 'cycle', 'week', 'weeks', 'month', 'months')
GROUP BY r.term;

-- Suggested statements: same drug class, same side effect, table numbers for both drugs
CREATE OR REPLACE VIEW HYPOTHESIS_SUGGESTIONS AS
WITH rates AS (
    SELECT drug, outcome, AVG(all_grade) AS avg_rate
    FROM TABLE_FACTS WHERE kind = 'table' AND all_grade IS NOT NULL
    GROUP BY drug, outcome
),
classes AS (SELECT DISTINCT drug, drug_class FROM DRUG_TERMS),
pairs AS (
    SELECT a.drug AS drug_a, b.drug AS drug_b, a.outcome, ca.drug_class,
           IFF(a.avg_rate < b.avg_rate, 'lower', 'higher') AS direction,
           ROUND(a.avg_rate, 1) AS a_rate, ROUND(b.avg_rate, 1) AS b_rate
    FROM rates a
    JOIN rates b    ON b.outcome = a.outcome AND a.drug < b.drug AND a.avg_rate <> b.avg_rate
    JOIN classes ca ON ca.drug = a.drug
    JOIN classes cb ON cb.drug = b.drug AND cb.drug_class = ca.drug_class
)
SELECT p.*,
       p.drug_a || ' appears to have a ' || p.direction || ' ' || p.outcome || ' rate than ' || p.drug_b AS hypothesis_text
FROM pairs p
LEFT JOIN HYPOTHESES h ON h.drug_a = p.drug_a AND h.drug_b = p.drug_b AND h.outcome = p.outcome
WHERE h.hypothesis_id IS NULL;

-- Quick look
SELECT hypothesis_text, verdict FROM HYPOTHESIS_SUMMARY ORDER BY hypothesis_id;
SELECT drug, suggested_class, documents, status FROM DRUG_CANDIDATES ORDER BY status DESC, documents DESC;