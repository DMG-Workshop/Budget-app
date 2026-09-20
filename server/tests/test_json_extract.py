from app.json_extract import extract_json_object


def test_reads_clean_json():
    assert extract_json_object('{"a": 1}') == {"a": 1}


def test_strips_a_markdown_fence():
    raw = 'Here is the audit:\n```json\n{"a": 2}\n```\nHope that helps!'
    assert extract_json_object(raw) == {"a": 2}


def test_strips_an_unlabelled_fence():
    assert extract_json_object('```\n{"a": 3}\n```') == {"a": 3}


def test_finds_the_outermost_object_amid_prose():
    assert extract_json_object('Sure. {"a": {"b": 4}} Done.') == {"a": {"b": 4}}


def test_ignores_braces_inside_strings():
    assert extract_json_object('prefix {"a": "}"} suffix') == {"a": "}"}


def test_ignores_escaped_quotes():
    assert extract_json_object(r'{"a": "say \"hi\" {"}') == {"a": 'say "hi" {'}


def test_returns_none_when_there_is_no_object():
    assert extract_json_object("no json here at all") is None
    assert extract_json_object("") is None
    assert extract_json_object("[1, 2, 3]") is None
