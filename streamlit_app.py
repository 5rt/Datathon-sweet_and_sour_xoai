"""
Breast Cancer Evidence Stress-Testing Assistant (Streamlit in Snowflake)

Tabs
  1  Stress-test a statement: rules find evidence, compare it fairly, summarise it,
     and a human reviews each result.
  2  Add a document: upload a public PDF/TXT/MD/JSON with its source details.
  3  Images: upload a public PNG/JPG/WebP, read it with OCR_IMAGE, analyse the facts.
  4  Vocabulary: drug names, brands, side effects and statements discovered in the
     documents, approved by a human before the rules use them.

Design
  - All logic lives in SQL views and two Snowflake functions (READ_DOC, OCR_IMAGE);
    the app only calls them, so it needs no extra Python packages.
  - Every user value is a bind parameter (?), never pasted into SQL.
  - Lookups are cached; anything that writes data clears the cache.
  - Not a diagnostic tool and not medical advice.
"""

import io
import re

import streamlit as st

session = st.connection("snowflake").session()
S = "EVIDENCE_DB.CORE"
QUALITY_SQL = ("CASE WHEN s.avg_conf >= 0.90 THEN 'Good' WHEN s.avg_conf >= 0.75 THEN 'Acceptable' "
               "WHEN s.avg_conf >= 0.50 THEN 'Poor' ELSE 'Unusable' END")
AUTO = "Detect automatically"


# ---------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------

def query(sql, params=None):
    """Run a SELECT and return a DataFrame."""
    return session.sql(sql, params=params).to_pandas()


def execute(sql, params=None):
    """Run a statement that changes data, then clear cached lookups."""
    session.sql(sql, params=params).collect()
    st.cache_data.clear()


@st.cache_data(ttl=600)
def cached(sql):
    """Cached SELECT for lookups that rarely change."""
    return query(sql)


def drugs():
    return cached(f"SELECT DISTINCT drug FROM {S}.DRUG_TERMS ORDER BY drug")["DRUG"].tolist()


def stage_bytes(stage, file_name):
    return session.file.get_stream(f"@{S}.{stage}/{file_name}").read()


def safe_file_name(name):
    return re.sub(r"[^A-Za-z0-9_.-]", "_", name)


def pick(label, frame, cols):
    """Selectbox over a DataFrame; returns the chosen row, or None if empty."""
    if frame.empty:
        return None
    labels = [f"{i + 1}. " + " | ".join(str(r[c]) for c in cols) for i, (_, r) in enumerate(frame.iterrows())]
    return frame.iloc[labels.index(st.selectbox(label, labels))]


def show_table(title, sql, params, empty, drop=()):
    st.markdown(f"### {title}")
    frame = query(sql, params)
    if frame.empty:
        st.info(empty)
    else:
        st.dataframe(frame.drop(columns=list(drop)), width="stretch")
    return frame


def upload_form(key, types, button):
    """Shared upload form. Returns (file, title, publisher, url, drug) or None."""
    with st.form(key):
        uploaded = st.file_uploader("File", type=types)
        title = st.text_input("Title")
        publisher = st.text_input("Publisher (e.g. Medsafe, Pharmac, US FDA)")
        url = st.text_input("Source URL")
        drug = st.selectbox("Main drug", [AUTO] + drugs() + ["multiple"])
        confirmed = st.checkbox("I confirm this file is public and contains no personal or patient information")
        if not st.form_submit_button(button):
            return None
    if uploaded is None or not title.strip() or not url.strip():
        st.error("Please add a file, a title and a source URL.")
        return None
    if not confirmed:
        st.error("Please confirm the file is public and has no personal information.")
        return None
    return uploaded, title.strip(), publisher.strip(), url.strip(), None if drug == AUTO else drug


def register_file(stage, kind, file_name, data, doc_type, title, publisher, url, drug, derived_tables):
    """Upload to a stage, replace any older version, write the library card and file fingerprint."""
    session.file.put_stream(io.BytesIO(data), f"@{S}.{stage}/{file_name}", auto_compress=False, overwrite=True)
    execute(f"ALTER STAGE {S}.{stage} REFRESH")
    for table in ("SOURCE_REGISTER", "STAGE_FILES", *derived_tables):
        execute(f"DELETE FROM {S}.{table} WHERE file_name = ?", [file_name])
    execute(f"""INSERT INTO {S}.SOURCE_REGISTER
                (file_name, title, publisher, source_url, doc_type, primary_drug, downloaded_on, why_chosen)
                VALUES (?, ?, ?, ?, ?, ?, CURRENT_DATE(), 'Uploaded through the app')""",
            [file_name, title, publisher, url, doc_type, drug])
    execute(f"""INSERT INTO {S}.STAGE_FILES
                SELECT RELATIVE_PATH, ?, MD5, SIZE, LAST_MODIFIED
                FROM DIRECTORY(@{S}.{stage}) WHERE RELATIVE_PATH = ?""", [kind, file_name])


# ---------------------------------------------------------------
# Sidebar
# ---------------------------------------------------------------

def sidebar():
    classes = cached(f"SELECT LISTAGG(DISTINCT drug_class, ', ') WITHIN GROUP (ORDER BY drug_class) AS C "
                     f"FROM {S}.DRUG_TERMS").iloc[0]["C"]
    st.sidebar.info(f"**Scope:** breast cancer. Drug classes: {classes or 'none yet'}.")

    st.sidebar.header("Add a statement to test")
    options = drugs()
    outcomes = cached(f"SELECT DISTINCT outcome FROM {S}.OUTCOME_TERMS ORDER BY outcome")["OUTCOME"].tolist()
    if len(options) < 2 or not outcomes:
        st.sidebar.warning("Approve at least two drugs and one side effect in the Vocabulary tab.")
    else:
        with st.sidebar.form("add_hypothesis"):
            a = st.selectbox("Drug A", options)
            b = st.selectbox("Drug B", options, index=1)
            outcome = st.selectbox("Side effect", outcomes)
            direction = st.radio("Drug A has a ___ rate than Drug B", ["lower", "higher"])
            if st.form_submit_button("Add"):
                if a == b:
                    st.error("Please pick two different drugs.")
                else:
                    execute(f"INSERT INTO {S}.HYPOTHESES (hypothesis_text, drug_a, drug_b, outcome, direction) "
                            "VALUES (?, ?, ?, ?, ?)",
                            [f"{a} appears to have a {direction} {outcome} rate than {b}", a, b, outcome, direction])
                    st.success("Statement added.")

    st.sidebar.divider()
    st.sidebar.caption("Sources (public documents only)")
    for r in cached(f"SELECT publisher, title FROM {S}.SOURCE_REGISTER ORDER BY publisher, title").itertuples():
        st.sidebar.caption(f"• {r.PUBLISHER}: {r.TITLE}")


# ---------------------------------------------------------------
# Tab 1: stress-test a statement
# ---------------------------------------------------------------

def show_verdict(hid):
    s = query(f"SELECT * FROM {S}.HYPOTHESIS_SUMMARY WHERE hypothesis_id = ?", [hid]).iloc[0]
    st.subheader(f"Verdict: {s['VERDICT']}")
    st.info(s["SUMMARY_TEXT"])
    for col, name in zip(st.columns(4), ("SUPPORTS", "LIMITS", "NOT_COMPARABLE", "NEEDS_REVIEW")):
        col.metric(name.replace("_", " ").capitalize(), int(s[name]))
    for side in ("A", "B"):
        if int(s[f"{side}_EVIDENCE"]) == 0:
            st.error(f"Not stated: no evidence found for {s[f'DRUG_{side}']}.")


def check_source(row):
    st.write(f"**Source:** {row['TITLE']} ({row['PUBLISHER']}), page {int(row['PAGE_NO'])}")
    st.write(f"**Link:** {row['SOURCE_URL']}")
    st.info(row["SNIPPET"])
    if row["EVIDENCE_TYPE"] == "ocr":
        with st.expander("Show the original image"):
            st.image(stage_bytes("IMAGES_STAGE", row["FILE_NAME"]), caption=row["FILE_NAME"])
        return
    page = query(f"SELECT page_text FROM {S}.DOC_PAGES WHERE file_name = ? AND page_no = ?",
                 [row["FILE_NAME"], int(row["PAGE_NO"])])
    if not page.empty:
        with st.expander("Show the full page"):
            st.text(page.iloc[0]["PAGE_TEXT"])


def review_form(hid, row):
    with st.form("review"):
        st.markdown("**Human review**")
        decision = st.radio("Is this evidence read correctly?", ["Agree", "Disagree", "Unsure"], horizontal=True)
        reviewer = st.text_input("Your name")
        note = st.text_input("Note (optional)")
        if st.form_submit_button("Save review"):
            if not reviewer.strip():
                st.error("Please enter your name.")
            else:
                execute(f"INSERT INTO {S}.REVIEWS (hypothesis_id, snippet_id, decision, note, reviewer) "
                        "VALUES (?, ?, ?, ?, ?)", [hid, row["SNIPPET_ID"], decision, note, reviewer.strip()])
                st.success("Review saved.")
    reviews = query(f"SELECT reviewed_at, reviewer, decision, note, snippet_id FROM {S}.REVIEWS "
                    "WHERE hypothesis_id = ? ORDER BY reviewed_at DESC", [hid])
    if not reviews.empty:
        with st.expander(f"Review log ({len(reviews)})"):
            st.dataframe(reviews, width="stretch")


def stress_test_tab():
    chosen = pick("Statement to stress-test",
                  query(f"SELECT hypothesis_id, hypothesis_text FROM {S}.HYPOTHESES ORDER BY hypothesis_id DESC"),
                  ["HYPOTHESIS_TEXT"])
    if chosen is None:
        st.info("No statements yet. Add one in the sidebar or the Vocabulary tab.")
        return
    hid = int(chosen["HYPOTHESIS_ID"])

    show_verdict(hid)
    show_table("Comparisons",
               f"""SELECT evidence_label, reason, drug_a, a_pct, a_grade, a_file, a_page,
                          drug_b, b_pct, b_grade, b_file, b_page
                   FROM {S}.COMPARISONS WHERE hypothesis_id = ? ORDER BY evidence_label""",
               [hid], "No pairs of numbers to compare.")
    evidence = show_table("Evidence found",
                          f"""SELECT drug, evidence_type, pct_value, grade, study_id, extract_status,
                                     publisher, title, source_url, file_name, page_no, snippet_id, snippet
                              FROM {S}.EVIDENCE WHERE hypothesis_id = ?
                              ORDER BY side, evidence_type, pct_value""",
                          [hid], "No evidence found.", drop=("SNIPPET", "SOURCE_URL", "SNIPPET_ID"))
    if evidence.empty:
        return
    st.markdown("### Check a result against the source")
    row = pick("Pick an evidence row", evidence, ["DRUG", "EVIDENCE_TYPE", "PAGE_NO", "EXTRACT_STATUS"])
    check_source(row)
    review_form(hid, row)


# ---------------------------------------------------------------
# Tab 2: add a document
# ---------------------------------------------------------------

def add_document_tab():
    st.markdown("### Add a public document")
    st.caption("PDF, TXT, Markdown or JSON. Public documents only: no patient or personal information.")
    fields = upload_form("add_document", ["pdf", "txt", "md", "json"], "Upload and read")
    if fields is None:
        return
    uploaded, title, publisher, url, drug = fields
    name = safe_file_name(uploaded.name)

    with st.spinner("Uploading and reading the document..."):
        register_file("DOCS_STAGE", "DOCS", name, uploaded.getvalue(), "Uploaded by user",
                      title, publisher, url, drug, ("DOC_PAGES", "SNIPPETS"))
        execute(f"""INSERT INTO {S}.DOC_PAGES (file_name, page_no, page_text)
                    SELECT d.file_name, p.page_no, p.page_text
                    FROM {S}.DOCUMENTS d,
                         TABLE({S}.READ_DOC(BUILD_SCOPED_FILE_URL(@{S}.DOCS_STAGE, d.file_name), d.file_name)) p
                    WHERE d.file_name = ?""", [name])
        execute(f"""INSERT INTO {S}.SNIPPETS
                    SELECT p.file_name || '|p' || p.page_no || '|s' || s.index,
                           p.file_name, p.page_no, s.index, TRIM(s.value)
                    FROM {S}.DOC_PAGES p,
                         LATERAL SPLIT_TO_TABLE(REGEXP_REPLACE(p.page_text, '[[:space:]]+', ' '), '. ') s
                    WHERE p.file_name = ? AND LENGTH(TRIM(s.value)) > 20""", [name])

    pages = query(f"SELECT COUNT(*) AS N FROM {S}.DOC_PAGES WHERE file_name = ?", [name]).iloc[0]["N"]
    st.success(f"Read {int(pages)} pages from {name}. It is now used for every statement.")


# ---------------------------------------------------------------
# Tab 3: images
# ---------------------------------------------------------------

def ocr_ready():
    return int(cached("SELECT COUNT(*) AS N FROM EVIDENCE_DB.INFORMATION_SCHEMA.FUNCTIONS "
                      "WHERE FUNCTION_SCHEMA = 'CORE' AND FUNCTION_NAME = 'OCR_IMAGE'").iloc[0]["N"]) > 0


def read_image(name):
    """OCR one image with the Snowflake function and save its lines. Returns (lines, confidence, label)."""
    execute(f"DELETE FROM {S}.OCR_RESULTS WHERE file_name = ?", [name])
    execute(f"""INSERT INTO {S}.OCR_RESULTS
                WITH lines AS (
                    SELECT line_no, text, confidence
                    FROM TABLE({S}.OCR_IMAGE(BUILD_SCOPED_FILE_URL(@{S}.IMAGES_STAGE, ?)))
                ),
                s AS (SELECT AVG(confidence) AS avg_conf FROM lines)
                SELECT ?, l.line_no, l.text, l.confidence, s.avg_conf, {QUALITY_SQL},
                       'RapidOCR (Snowflake function)', CURRENT_TIMESTAMP()
                FROM lines l CROSS JOIN s""", [name, name])
    r = query(f"SELECT COUNT(*) AS N, MAX(file_confidence) AS C, MAX(quality_label) AS L "
              f"FROM {S}.OCR_RESULTS WHERE file_name = ?", [name]).iloc[0]
    if int(r["N"]) == 0:   # no text at all: record it so the image isn't silently skipped
        execute(f"INSERT INTO {S}.OCR_RESULTS VALUES (?, 0, NULL, NULL, NULL, 'Unusable', "
                "'RapidOCR (Snowflake function)', CURRENT_TIMESTAMP())", [name])
        return 0, None, "Unusable"
    return int(r["N"]), r["C"], r["L"]


def upload_image_section(ready):
    st.markdown("### Add an image")
    st.caption("PNG, JPG or WebP. Public images of printed text only (e.g. a screenshot of a data sheet table). "
               "No photos of people, scans or records of patients. This tool does not diagnose.")
    fields = upload_form("add_image", ["png", "jpg", "jpeg", "webp"], "Upload and analyse")
    if fields is None:
        return
    uploaded, title, publisher, url, drug = fields
    name = safe_file_name(uploaded.name)
    with st.spinner("Saving the image..."):
        register_file("IMAGES_STAGE", "IMAGES", name, uploaded.getvalue(), "Image",
                      title, publisher, url, drug, ("OCR_RESULTS",))
    if not ready:
        st.warning("Image saved. It will be read once the OCR_IMAGE function exists.")
        return
    with st.spinner("Reading text (the first run can take up to a minute)..."):
        count, conf, label = read_image(name)
    st.success(f"Read {count} lines. Image quality: {label}"
               + (f" (average confidence {conf:.2f})." if conf is not None else ".")
               + " Pick it below to see the analysis.")


def waiting_images_section(ready):
    waiting = query(f"""SELECT d.file_name FROM {S}.DOCUMENTS d
                        LEFT JOIN (SELECT DISTINCT file_name FROM {S}.OCR_RESULTS) o ON o.file_name = d.file_name
                        WHERE d.source_stage = 'IMAGES' AND d.source_url IS NOT NULL AND o.file_name IS NULL
                        ORDER BY d.file_name""")["FILE_NAME"].tolist()
    if not waiting:
        return
    st.markdown("### Images waiting to be read")
    st.write(", ".join(waiting))
    if ready and st.button(f"Read waiting images ({len(waiting)})"):
        bar = st.progress(0.0)
        for i, name in enumerate(waiting, start=1):
            read_image(name)
            bar.progress(i / len(waiting))
        st.success("All waiting images have been read.")


def image_analysis_section(ready):
    st.markdown("### Image analysis")
    profiles = query(f"SELECT * FROM {S}.IMAGE_PROFILE ORDER BY avg_confidence DESC NULLS LAST")
    if profiles.empty:
        st.info("No analysed images yet. Upload one above.")
        return

    counts = profiles["QUALITY_LABEL"].value_counts()
    for col, label in zip(st.columns(4), ("Good", "Acceptable", "Poor", "Unusable")):
        col.metric(label, int(counts.get(label, 0)))
    st.dataframe(profiles[["FILE_NAME", "CONTENT_TYPE", "DRUGS_DETECTED", "DRUG_CHECK",
                           "QUALITY_LABEL", "OUTCOMES_FOUND", "MATCHES_PDF", "DIFFERS_PDF"]], width="stretch")

    row = pick("Pick an image to inspect", profiles, ["FILE_NAME"])
    name = row["FILE_NAME"]
    st.info(row["SUMMARY_TEXT"])

    left, right = st.columns(2)
    with left:
        st.image(stage_bytes("IMAGES_STAGE", name), caption=name)
        if ready and st.button("Read this image again"):
            with st.spinner("Reading text again..."):
                read_image(name)
            st.success("Done. The analysis has been refreshed.")
    with right:
        for label, key in (("Content type", "CONTENT_TYPE"), ("Main drug", "REGISTERED_DRUG"),
                           ("Drugs detected", "DRUGS_DETECTED"), ("Trial mentioned", "TRIAL_MENTIONED"),
                           ("Quality", "QUALITY_LABEL"), ("Confidence", "AVG_CONFIDENCE"), ("Source", "SOURCE_URL")):
            st.write(f"**{label}:** {row[key]}")
        (st.warning if str(row["DRUG_CHECK"]).startswith("Check") else st.write)(f"**Drug check:** {row['DRUG_CHECK']}")
        if row["QUALITY_LABEL"] in ("Poor", "Unusable"):
            st.warning("Low quality: this image is NOT used as evidence.")
        else:
            st.info("Used as evidence, always marked 'Needs review'.")

    show_table("Structured facts from this image",
               f"""SELECT outcome, fact_type, any_grade_pct, grade3_4_pct, pdf_any_grade_pct,
                          cross_check, status, evidence_text
                   FROM {S}.IMAGE_FACTS WHERE file_name = ? ORDER BY outcome""",
               [name], "No side-effect information found in this image.")
    with st.expander("Raw OCR lines"):
        st.dataframe(query(f"SELECT line_no, ocr_text, ROUND(line_confidence, 2) AS confidence "
                           f"FROM {S}.OCR_RESULTS WHERE file_name = ? ORDER BY line_no", [name]), width="stretch")


def images_tab():
    ready = ocr_ready()
    (st.success if ready else st.error)(
        "OCR ready: text is read by the OCR_IMAGE Snowflake function (RapidOCR, no Snowflake AI)." if ready
        else "The OCR_IMAGE function is missing. Run sql/06_functions.sql, then reload the app.")
    upload_image_section(ready)
    waiting_images_section(ready)
    st.divider()
    image_analysis_section(ready)


# ---------------------------------------------------------------
# Tab 4: vocabulary (discovered by rules, approved by a human)
# ---------------------------------------------------------------

def approve_section(title, frame, cols, key, insert_sql, to_params):
    st.markdown(f"### {title}")
    if frame.empty:
        st.info("Nothing new found.")
        return
    st.dataframe(frame[cols], width="stretch")
    labels = [f"{i + 1}. " + " | ".join(str(r[c]) for c in cols[:2]) for i, (_, r) in enumerate(frame.iterrows())]
    chosen = st.multiselect("Tick the ones to approve", labels, key=key)
    if chosen and st.button(f"Approve {len(chosen)}", key=f"{key}_approve"):
        for label in chosen:
            execute(insert_sql, to_params(frame.iloc[labels.index(label)]))
        st.success(f"Approved {len(chosen)}. The rules use them straight away.")
        st.rerun()


def vocabulary_tab():
    st.caption("Drug names, brands and side effects are discovered in the documents by rules. "
               "A human approves them before the evidence rules use them. Nothing is added automatically.")
    approve_section(
        "New drug names found",
        query(f"SELECT * FROM {S}.DRUG_CANDIDATES WHERE status = 'New' ORDER BY documents DESC, mentions DESC"),
        ["DRUG", "SUGGESTED_CLASS", "DOCUMENTS", "MENTIONS"], "drugs",
        f"INSERT INTO {S}.DRUG_TERMS VALUES (?, ?, ?, 'Breast cancer')",
        lambda r: [r["DRUG"], r["DRUG"], r["SUGGESTED_CLASS"]])
    approve_section(
        "Brand names found",
        query(f"SELECT * FROM {S}.BRAND_CANDIDATES WHERE status = 'New' ORDER BY brand"),
        ["BRAND", "DRUG", "GENERIC_TEXT", "FILE_NAME"], "brands",
        f"INSERT INTO {S}.DRUG_TERMS SELECT ?, ?, MAX(drug_class), 'Breast cancer' FROM {S}.DRUG_TERMS WHERE drug = ?",
        lambda r: [r["DRUG"], r["BRAND"], r["DRUG"]])
    approve_section(
        "Side effects found in adverse-reaction tables",
        query(f"SELECT * FROM {S}.OUTCOME_CANDIDATES WHERE status = 'New' "
              "ORDER BY documents DESC, mentions DESC LIMIT 50"),
        ["TERM", "DOCUMENTS", "MENTIONS"], "outcomes",
        f"INSERT INTO {S}.OUTCOME_TERMS VALUES (?, ?)",
        lambda r: [r["TERM"], r["TERM"]])
    approve_section(
        "Suggested statements to stress-test",
        query(f"SELECT * FROM {S}.HYPOTHESIS_SUGGESTIONS ORDER BY drug_class, outcome"),
        ["HYPOTHESIS_TEXT", "A_RATE", "B_RATE", "DRUG_CLASS"], "statements",
        f"INSERT INTO {S}.HYPOTHESES (hypothesis_text, drug_a, drug_b, outcome, direction) VALUES (?, ?, ?, ?, ?)",
        lambda r: [r["HYPOTHESIS_TEXT"], r["DRUG_A"], r["DRUG_B"], r["OUTCOME"], r["DIRECTION"]])


# ---------------------------------------------------------------
# Page layout
# ---------------------------------------------------------------

st.title("Breast Cancer Evidence Stress-Testing Assistant")
st.warning("Research and education tool only. It checks whether published evidence is enough to support "
           "a statement. It does NOT diagnose or give medical advice. A human must review every result.")

sidebar()

for tab, render in zip(st.tabs(["Stress-test a statement", "Add a document", "Images", "Vocabulary"]),
                       (stress_test_tab, add_document_tab, images_tab, vocabulary_tab)):
    with tab:
        render()

st.caption("Sources: Medsafe, US FDA, NICE, NCI, Pharmac (public documents only). "
           "No patient data is used. Not medical advice.")