# HER2-positive breast cancer drug evidence pack

## Corrected project direction

This pack focuses on medicines used in different **HER2-positive breast cancer treatment settings** and includes drug side effects. It replaces the earlier image-only breast-ultrasound direction as the main dataset.

Use these three settings for the MVP:

1. **Early / locally advanced, neoadjuvant or adjuvant:** trastuzumab and pertuzumab.
2. **Residual invasive disease after neoadjuvant therapy:** trastuzumab emtansine (T-DM1 / Kadcyla).
3. **Unresectable or metastatic disease:** trastuzumab, pertuzumab, T-DM1 and trastuzumab deruxtecan (T-DXd / Enhertu), depending on treatment line and document date.

Stage number alone is not enough to select a medicine. Retain HER2 status, hormone-receptor status, prior treatment, treatment line and jurisdiction.

## Mixed source formats

- `pdfs/`: original PDF evidence, including New Zealand and U.S. labels, a NICE guideline, FDA reviews and a clinical-trial paper.
- `text_sources/`: independent text records derived from relevant official webpages. These are not PDF conversions.
- `images/`: three chart-page images rendered from source PDFs for the demo.
- `metadata/source_manifest.json`: machine-readable source index. No CSV is used.

## Three chart-bearing evidence files

- `10_aphinity_early_stage_fda_review.pdf`: early-stage adjuvant pertuzumab; contains an IDFS Kaplan-Meier chart.
- `12_katherine_residual_disease_fda_label.pdf`: residual invasive disease; contains the KATHERINE IDFS Kaplan-Meier chart.
- `11_destiny_breast03_trial.pdf`: previously treated metastatic disease; contains efficacy tables and survival curves comparing T-DXd with T-DM1.

## Recommended demo hypothesis

> Across HER2-positive breast cancer treatment settings, cardiac monitoring remains a recurring safety requirement, while thrombocytopenia/hepatotoxicity are especially important for T-DM1 and interstitial lung disease/pneumonitis is especially important for T-DXd.

The tool should return `supported`, `contradicted`, `not stated`, or `not comparable` for each part of the hypothesis and preserve the exact source file, page or webpage URL, publication date and quoted evidence.

## Suggested JSON output fields

`document_id`, `source_format`, `title`, `jurisdiction`, `publication_or_revision_date`, `disease_setting`, `stage_text`, `biomarker`, `drug`, `regimen`, `treatment_line`, `endpoint`, `result`, `adverse_effect`, `severity_grade`, `frequency`, `monitoring_requirement`, `supporting_text`, `page_number`, `source_url`, `comparison_status`, `review_status`

## Important limitation

Adverse-event percentages from different trials or labels are usually **not directly comparable** because populations, regimens, follow-up periods and reporting rules differ. The prototype is an evidence-review assistant, not a treatment recommendation system.

