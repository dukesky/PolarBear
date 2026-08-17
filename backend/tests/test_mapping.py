import pytest


def test_guess_mapping_on_shopify_export():
    from app.services.ingestion.mapping import guess_mapping

    g = guess_mapping(
        ["Handle", "Title", "Body (HTML)", "Vendor", "Type", "Tags",
         "Variant SKU", "Variant Price", "Image Src"]
    )
    assert g["title"] == "Title"
    assert g["description"] == "Body (HTML)"
    assert g["price"] == "Variant Price"
    assert g["image_url"] == "Image Src"
    assert g["brand"] == "Vendor"
    assert g["tags"] == "Tags"
    assert g["id"] in ("Handle", "Variant SKU")  # both are id-ish; first match wins
    assert g["category"] == "Type"


def test_guess_mapping_handles_plain_spreadsheet_and_chinese():
    from app.services.ingestion.mapping import guess_mapping

    g = guess_mapping(["Product Name", "Price"])
    assert g["title"] == "Product Name"
    assert g["price"] == "Price"
    assert g["id"] is None

    g2 = guess_mapping(["商品名称", "价格", "描述"])
    assert g2["title"] == "商品名称"
    assert g2["price"] == "价格"
    assert g2["description"] == "描述"


def test_guess_mapping_never_reuses_a_column():
    from app.services.ingestion.mapping import guess_mapping

    g = guess_mapping(["name"])
    assigned = [v for v in g.values() if v is not None]
    assert assigned == ["name"]


def test_slugify_and_generated_ids_are_stable_and_unique():
    from app.services.ingestion.mapping import generate_ids, slugify

    assert slugify("Adjustable Wrench 10 inch!") == "adjustable-wrench-10-inch"
    assert slugify("   ") == ""

    ids = generate_ids(["Blue Mug", "Blue Mug", "Red Mug", ""])
    assert ids == ["blue-mug", "blue-mug-2", "red-mug", "item-4"]
    # stable across identical input
    assert generate_ids(["Blue Mug", "Blue Mug", "Red Mug", ""]) == ids


def test_strip_html_and_coerce_price():
    from app.services.ingestion.mapping import coerce_price, strip_html

    assert strip_html("<p>Warm &amp; soft</p><br/>blanket") == "Warm & soft blanket"
    assert strip_html("") == ""
    assert coerce_price("$1,299.50") == 1299.5
    assert coerce_price(12) == 12.0
    assert coerce_price("call us") == "call us"


def test_build_documents_maps_generates_ids_and_drops_extras():
    from app.services.ingestion.mapping import build_documents

    rows = [
        {"Handle": "", "Title": "Blue Mug", "Body (HTML)": "<b>Ceramic</b> mug",
         "Variant Price": "$12.00", "Junk": "ignore me"},
        {"Handle": "", "Title": "Red Mug", "Body (HTML)": "", "Variant Price": "",
         "Junk": "ignore me"},
    ]
    mapping = {"id": None, "title": "Title", "description": "Body (HTML)",
               "price": "Variant Price", "category": None, "brand": None,
               "tags": None, "image_url": None, "url": None}

    docs = build_documents(rows, mapping)
    assert [d["id"] for d in docs] == ["blue-mug", "red-mug"]
    assert docs[0]["description"] == "Ceramic mug"
    assert docs[0]["price"] == 12.0
    assert "Junk" not in docs[0]
    assert docs[0]["image_url"] == ""  # unmapped targets present but empty


def test_build_documents_requires_title():
    from app.services.ingestion.mapping import build_documents

    with pytest.raises(ValueError, match="title"):
        build_documents([{"A": "x"}], {"id": "A", "title": None})


def test_build_documents_rejects_unknown_source_column():
    from app.services.ingestion.mapping import build_documents

    with pytest.raises(ValueError, match="Nope"):
        build_documents([{"A": "x"}], {"title": "Nope"})


def test_sanitize_id_makes_merchant_skus_safe():
    from app.services.ingestion.mapping import sanitize_id

    assert sanitize_id("ABC 123") == "ABC-123"
    assert sanitize_id("SHIRT/RED/L") == "SHIRT-RED-L"
    assert sanitize_id("#1001") == "1001"
    assert sanitize_id("ok_id-9") == "ok_id-9"
    assert sanitize_id("###") == ""


def test_build_documents_sanitizes_and_dedupes_mapped_ids():
    from app.services.ingestion.mapping import build_documents

    rows = [
        {"SKU": "ABC 123", "Title": "First"},
        {"SKU": "ABC/123", "Title": "Second"},   # sanitizes to the same value
        {"SKU": "", "Title": "Third Item"},       # falls back to generated id
        {"SKU": "###", "Title": "Fourth Item"},   # sanitizes to empty -> generated
    ]
    mapping = {"id": "SKU", "title": "Title"}
    docs = build_documents(rows, mapping)
    ids = [d["id"] for d in docs]

    assert ids[0] == "ABC-123"
    assert ids[1] == "ABC-123-2"
    assert ids[2] == "third-item"
    assert ids[3] == "fourth-item"
    import re as _re
    assert all(_re.fullmatch(r"[a-zA-Z0-9_-]+", i) for i in ids)


def test_generated_ids_are_meilisearch_legal_for_cjk_titles():
    import re
    from app.services.ingestion.mapping import build_documents, generate_ids

    ids = generate_ids(["蓝色马克杯", "红色马克杯", "蓝色马克杯"])
    assert all(re.fullmatch(r"[a-zA-Z0-9_-]+", i) for i in ids), ids
    assert len(set(ids)) == 3  # still unique

    docs = build_documents(
        [{"名称": "蓝色马克杯"}, {"名称": "红色马克杯"}], {"title": "名称"}
    )
    assert all(re.fullmatch(r"[a-zA-Z0-9_-]+", d["id"]) for d in docs)
