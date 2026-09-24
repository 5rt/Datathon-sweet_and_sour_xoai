USE ROLE EVIDENCE_DEV;
USE WAREHOUSE EVIDENCE_WH;
USE SCHEMA EVIDENCE_DB.CORE;

-- Tables: created once. Existing rows (including app approvals) are always kept.
CREATE TABLE IF NOT EXISTS DRUG_TERMS    (drug STRING, term STRING, drug_class STRING, cancer_type STRING);
CREATE TABLE IF NOT EXISTS OUTCOME_TERMS (outcome STRING, term STRING);

CREATE TABLE IF NOT EXISTS HYPOTHESES (
    hypothesis_id    INT AUTOINCREMENT,
    hypothesis_text  STRING,
    drug_a           STRING,
    drug_b           STRING,
    outcome          STRING,
    direction        STRING,                           -- 'lower' or 'higher' (Drug A vs Drug B)
    created_by       STRING DEFAULT CURRENT_USER(),
    created_at       TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE TABLE IF NOT EXISTS REVIEWS (
    review_id      INT AUTOINCREMENT,
    hypothesis_id  INT,
    snippet_id     STRING,
    decision       STRING,                             -- Agree / Disagree / Unsure
    note           STRING,
    reviewer       STRING,
    reviewed_at    TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE TABLE IF NOT EXISTS OCR_RESULTS (
    file_name        STRING,
    line_no          INT,
    ocr_text         STRING,
    line_confidence  FLOAT,
    file_confidence  FLOAT,
    quality_label    STRING,                           -- Good / Acceptable / Poor / Unusable
    ocr_engine       STRING,
    processed_at     TIMESTAMP_LTZ
);

CREATE TABLE IF NOT EXISTS GOLD_LABELS (
    gold_id      INT AUTOINCREMENT,
    file_name    STRING,
    drug         STRING,
    outcome      STRING,
    grade        STRING,                               -- 'Any grade' or 'Grade 3-4'
    value        FLOAT,                                -- % read by a person
    labelled_by  STRING,
    note         STRING
);

-- Starter vocabulary: just the first demo drug class.
-- Anti-HER2 drugs, taxanes, brands and other side effects are discovered and approved in the app.
MERGE INTO DRUG_TERMS t
USING (SELECT * FROM VALUES
        ('palbociclib', 'palbociclib', 'CDK4/6 inhibitor', 'Breast cancer'),
        ('palbociclib', 'ibrance',     'CDK4/6 inhibitor', 'Breast cancer'),
        ('abemaciclib', 'abemaciclib', 'CDK4/6 inhibitor', 'Breast cancer'),
        ('abemaciclib', 'verzenio',    'CDK4/6 inhibitor', 'Breast cancer'),
        ('ribociclib',  'ribociclib',  'CDK4/6 inhibitor', 'Breast cancer'),
        ('ribociclib',  'kisqali',     'CDK4/6 inhibitor', 'Breast cancer')
       AS v(drug, term, drug_class, cancer_type)) s
ON t.drug = s.drug AND t.term = s.term
WHEN NOT MATCHED THEN INSERT VALUES (s.drug, s.term, s.drug_class, s.cancer_type);

MERGE INTO OUTCOME_TERMS t
USING (SELECT * FROM VALUES
        ('neutropenia',     'neutropenia'),
        ('neutropenia',     'neutrophil count decreased'),
        ('diarrhoea',       'diarrhoea'),
        ('diarrhoea',       'diarrhea'),
        ('QT prolongation', 'electrocardiogram qt prolonged'),
        ('QT prolongation', 'qt prolongation')
       AS v(outcome, term)) s
ON t.outcome = s.outcome AND t.term = s.term
WHEN NOT MATCHED THEN INSERT VALUES (s.outcome, s.term);

MERGE INTO HYPOTHESES t
USING (SELECT * FROM VALUES
        ('Abemaciclib appears to have a lower neutropenia rate than palbociclib',
         'abemaciclib', 'palbociclib', 'neutropenia', 'lower'),
        ('Abemaciclib appears to have a higher diarrhoea rate than palbociclib',
         'abemaciclib', 'palbociclib', 'diarrhoea', 'higher'),
        ('Ribociclib appears to have a higher QT prolongation rate than palbociclib',
         'ribociclib', 'palbociclib', 'QT prolongation', 'higher')
       AS v(hypothesis_text, drug_a, drug_b, outcome, direction)) s
ON t.hypothesis_text = s.hypothesis_text
WHEN NOT MATCHED THEN INSERT (hypothesis_text, drug_a, drug_b, outcome, direction)
                      VALUES (s.hypothesis_text, s.drug_a, s.drug_b, s.outcome, s.direction);

SELECT drug_class, COUNT(DISTINCT drug) AS drugs, COUNT(*) AS terms FROM DRUG_TERMS GROUP BY drug_class;