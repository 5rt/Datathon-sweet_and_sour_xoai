# Breast Cancer Evidence Stress-Testing Assistant

A tool that checks whether published evidence is actually strong enough to back up a claim like *"Drug A causes less neutropenia than Drug B."*

It reads public documents about breast cancer medicines, finds the relevant numbers, and tells you whether they can fairly be compared. Every number links back to the page or image it came from, and a human always makes the final call.

> ⚠️ Research and education tool only. It doesn't diagnose and doesn't give medical advice.

Built for the **University of Auckland Datathon 2026** (Use case 3: From documents to structured insights).

---

## Why we built it

Side-effect rates for different drugs often get compared even when they come from different trials with different patients, doses and definitions of severity. Those numbers can look convincing but aren't a fair comparison. We wanted a tool that catches that.

## What it does

- **Reads documents inside Snowflake:** PDF, TXT, Markdown, JSON, and images (PNG, JPG, WebP) via OCR
- **Finds evidence** in sentences and in side-effect tables
- **Compares fairly:** each pair of numbers is labelled **Supports**, **Limits** or **Not comparable** (different trials or severity grades)
- **Gives a verdict and a plain-English summary** for each statement
- **Checks image numbers** against the official PDFs and ignores blurry images
- **Learns new vocabulary:** it finds new drug names, brands and side effects in the documents, and we approve them before they're used
- **Keeps a review log:** every human check is saved with a name and time

No AI makes decisions. It's all transparent rules, so every result can be explained.

---

## How it works

```
Public documents & images
        │
        ▼
Encrypted Snowflake stages  ──►  Library cards (source, URL, fingerprint)
        │
        ├──►  READ_DOC   (PDF / TXT / MD / JSON → pages → sentences)
        └──►  OCR_IMAGE  (images → text lines + quality label)
        │
        ▼
SQL rule views  ──►  evidence → comparisons → verdict + summary
        │
        ▼
Streamlit app  ──►  human review (saved)   ◄──  approve new vocabulary
```

## Tech stack

- **Snowflake:** stages, SQL views, Python functions (PyPDF2, RapidOCR)
- **Streamlit in Snowflake:** the app
- **GitHub Actions:** CI/CD

---

## Repo structure

```
sql/
  00_reset.sql        clean up old objects (keeps data)
  01_setup.sql        warehouse, database, roles, cost limit
  02_stages.sql       file storage
  03_vocabulary.sql   tables + starter word lists
  04_sources.sql      library cards for every file
  05_documents.sql    register files + fingerprints
  06_functions.sql    READ_DOC and OCR_IMAGE
  07_pages.sql        pages, sentences, OCR
  08_rules.sql        all the rules (views only)
  09_tests.sql        data tests (all should be 0)
  10_accuracy.sql     precision / recall check
app/
  streamlit_app.py    the app
docs/
  HANDOVER.md         full project notes
.github/workflows/
  ci.yml  cd.yml
```

---

## Getting started

**You'll need:** a Snowflake account (a trial works) and the documents uploaded to the stages.

1. Run `00_reset.sql` and `01_setup.sql` as **ACCOUNTADMIN**. Add your username in `01_setup.sql` first.
2. Switch to the **EVIDENCE_DEV** role.
3. Run `02_stages.sql`, then upload your documents to `DOCS_STAGE` (Snowsight → Catalog → Stages → **+ Files**).
4. Run `03` to `09` in order. Use **Ctrl + Shift + Enter** so the whole file runs.
5. Check `09_tests.sql`: every row should say **0**.
6. Create a Streamlit app (Projects → Streamlit), paste in `app/streamlit_app.py`, and hit **Run**.

Every script is safe to run again. It won't delete reviews, approvals or OCR results.

## Using the app

| Tab | What you do there |
|---|---|
| **Stress-test** | Pick a statement, see the verdict, check evidence against the source, leave a review |
| **Add a document** | Upload a public PDF, TXT, Markdown or JSON file |
| **Images** | Upload a screenshot or photo of printed text, see what was read and how reliable it is |
| **Vocabulary** | Approve new drugs, brands, side effects and suggested statements found in the documents |

---

## Data and privacy

- **Public documents only:** Medsafe, US FDA, NICE, NCI, Pharmac and published trials
- **No patient or personal data.** Upload forms ask you to confirm this.
- Every file has a **library card** (publisher, source URL, reason for inclusion) and an **MD5 fingerprint**
- Original files are never changed
- Built with the NZ Privacy Act 2020 and Health Information Privacy Code 2020 in mind

## Security

- A separate team role for day-to-day work; admin is only used for setup
- All user input goes in as parameters (no SQL injection)
- No passwords or tokens in the repo. CI blocks them.
- CD runs as a service user with key-pair login
- Cost controls: extra-small warehouse, 60-second auto-suspend, 20-credit limit. The whole build used about 1 credit.

## Testing

- **`09_tests.sql`** checks for missing sources, personal data flags, unread files, unapproved drugs and OCR issues. Everything should be 0.
- **`10_accuracy.sql`** compares the rules against numbers we read by hand, and reports precision and recall for sentences only vs sentences + tables.

## CI/CD

- **CI (every pull request):** lints SQL, checks the app compiles, blocks secrets and risky `DROP` statements, and makes sure `08_rules.sql` only has views
- **CD (merge to main):** deploys `08_rules.sql`, runs the tests, and does a quick smoke test

Files 01–07 are run by hand on purpose, so a deploy can never wipe data.

---

## Known limitations

- Rules only catch patterns we've written, so unusual wording or table layouts can be missed
- "Trastuzumab" also appears inside "trastuzumab emtansine" and "trastuzumab deruxtecan", so some sentences match more than one drug
- OCR quality depends on the image
- Scanned PDFs need to be uploaded as images
- English only for now

## What's next

- AI summaries of the selected evidence (Cortex or Bedrock), with citation checks and human review
- OCR for scanned PDFs page by page
- An evidence-quality score (trial size, head-to-head or not)
- More cancers and drug classes, added through the Vocabulary tab with no code changes

---

## Team

| Name | Role |
|---|---|
| | Project coordinator |
| | Data engineer |
| | Data analyst |
| | Solution designer |
| | Cloud engineer |

## Sources

Documents from [Medsafe](https://www.medsafe.govt.nz), [US FDA](https://www.accessdata.fda.gov), [NICE](https://www.nice.org.uk), [NCI](https://www.cancer.gov) and [Pharmac](https://www.pharmac.govt.nz). All belong to their publishers and are used here for research and education.
