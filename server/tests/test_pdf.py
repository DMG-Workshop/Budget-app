from app.ingest.pdf import extract_text

from .conftest import STATEMENT_LINES, make_pdf


def test_reads_the_text_layer_of_a_real_pdf(statement_pdf):
    result = extract_text(statement_pdf)
    assert result.succeeded
    assert result.page_count == 1
    assert "DELIVEROO ORDER" in result.text
    assert "GREENFIELD LETTINGS RENT" in result.text


def test_marks_page_boundaries():
    result = extract_text(make_pdf(STATEMENT_LINES))
    assert "--- page 1 ---" in result.text


def test_reports_a_pdf_with_no_text_layer_rather_than_raising():
    # A page with no content stream is the closest thing to a scan that can
    # be built without embedding an image.
    blank = make_pdf([])
    result = extract_text(blank)
    assert not result.succeeded
    assert "no text layer" in result.failure


def test_never_raises_on_a_file_that_is_not_a_pdf():
    result = extract_text(b"this is not a pdf at all")
    assert not result.succeeded
    assert result.failure
