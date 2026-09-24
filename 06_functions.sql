USE ROLE EVIDENCE_DEV;
USE WAREHOUSE EVIDENCE_WH;
USE SCHEMA EVIDENCE_DB.CORE;

CREATE OR REPLACE FUNCTION READ_DOC(file_url STRING, file_name STRING)
RETURNS TABLE (page_no INT, page_text STRING)
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python', 'PyPDF2')
HANDLER = 'ReadDoc'
AS $$
import json
from io import BytesIO
from snowflake.snowpark.files import SnowflakeFile
from PyPDF2 import PdfReader


def json_lines(value, path=''):
    """Flatten JSON into 'path: value.' lines so the sentence rules can read it."""
    if isinstance(value, dict):
        for key, item in value.items():
            yield from json_lines(item, f'{path}.{key}' if path else str(key))
    elif isinstance(value, list):
        for i, item in enumerate(value):
            yield from json_lines(item, f'{path}[{i}]')
    else:
        yield f'{path}: {value}.'


class ReadDoc:
    def process(self, file_url, file_name):
        # A file that can't be opened or parsed is skipped (no pages) instead of stopping
        # the whole run. 09_tests.sql then reports it under "documents with no pages read".
        try:
            with SnowflakeFile.open(file_url, 'rb') as f:        # read-only: the original never changes
                data = f.readall()
        except Exception:
            return

        name = file_name.lower()
        if name.endswith('.pdf'):
            try:
                pages = PdfReader(BytesIO(data)).pages
            except Exception:
                return
            for i, page in enumerate(pages, start=1):
                try:
                    yield (i, page.extract_text() or '')
                except Exception:
                    yield (i, '')                                  # one broken page doesn't lose the rest
            return

        text = data.decode('utf-8', errors='replace')
        if name.endswith('.json'):
            try:
                text = '\n'.join(json_lines(json.loads(text)))
            except ValueError:
                pass                                               # not valid JSON: keep raw text
        yield (1, text)                                            # .txt, .md and .json are one page
$$;

-- Images -> lines of text with confidence (RapidOCR from Snowflake's own PyPI copy)
CREATE OR REPLACE FUNCTION OCR_IMAGE(file_url STRING)
RETURNS TABLE (line_no INT, text STRING, confidence FLOAT)
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
ARTIFACT_REPOSITORY = snowflake.snowpark.pypi_shared_repository
PACKAGES = ('snowflake-snowpark-python', 'rapidocr_onnxruntime', 'opencv-python-headless')
HANDLER = 'OcrImage'
AS $$
import io
import numpy as np
from snowflake.snowpark.files import SnowflakeFile

_engine = None


def engine():
    """Load the small RapidOCR model once per process."""
    global _engine
    if _engine is None:
        from rapidocr_onnxruntime import RapidOCR
        _engine = RapidOCR()
    return _engine


class OcrImage:
    def process(self, file_url):
        import cv2
        with SnowflakeFile.open(file_url, 'rb') as f:
            data = f.readall()
        image = cv2.imdecode(np.frombuffer(data, np.uint8), cv2.IMREAD_COLOR)
        if image is None:                                    # WebP or unusual files: use Pillow
            from PIL import Image
            image = cv2.cvtColor(np.array(Image.open(io.BytesIO(data)).convert('RGB')), cv2.COLOR_RGB2BGR)
        result, _ = engine()(image, use_cls=False)
        for i, (_, text, confidence) in enumerate(result or [], start=1):
            yield (i, text, float(confidence))
$$;