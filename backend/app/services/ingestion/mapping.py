"""Turn an arbitrary product export into PolarBear documents.

Merchants upload Shopify exports, WooCommerce exports, and hand-made
spreadsheets. This module guesses which column means what, then builds
documents from a confirmed mapping.
"""

import html
import re

TARGET_FIELDS = [
    "id", "title", "description", "price",
    "category", "brand", "tags", "image_url", "url",
]

# Normalized header aliases, most specific first.
ALIASES: dict[str, list[str]] = {
    "id": ["id", "sku", "variantsku", "productid", "itemid", "itemnumber",
           "code", "handle", "货号", "编号"],
    "title": ["title", "name", "productname", "producttitle", "product",
              "item", "itemname", "名称", "商品名", "商品名称"],
    "description": ["description", "desc", "details", "body", "bodyhtml",
                    "longdescription", "描述", "详情"],
    "price": ["price", "variantprice", "unitprice", "cost", "amount",
              "价格", "售价"],
    "category": ["category", "producttype", "type", "productcategory",
                 "collection", "分类", "类别"],
    "brand": ["brand", "vendor", "manufacturer", "supplier", "品牌"],
    "tags": ["tags", "keywords", "labels", "标签"],
    "image_url": ["imageurl", "imagesrc", "image", "photo", "picture",
                  "thumbnail", "图片"],
    "url": ["url", "link", "producturl", "productlink", "permalink", "链接"],
}


def normalize_header(name: str) -> str:
    return re.sub(r"[^a-z0-9一-鿿]", "", str(name).lower())


def guess_mapping(columns: list[str]) -> dict[str, str | None]:
    """Best-effort target -> source column. Every target is present as a key."""
    normalized = [(c, normalize_header(c)) for c in columns]
    taken: set[str] = set()
    out: dict[str, str | None] = {}
    for target in TARGET_FIELDS:
        found = None
        for alias in ALIASES[target]:
            for original, norm in normalized:
                if original in taken:
                    continue
                if norm == alias:
                    found = original
                    break
            if found:
                break
        if found:
            taken.add(found)
        out[target] = found
    return out


def slugify(text: str) -> str:
    s = re.sub(r"[^a-z0-9一-鿿]+", "-", str(text).lower()).strip("-")
    return s[:64].strip("-")


def sanitize_id(value: str) -> str:
    """Meilisearch only accepts a-z A-Z 0-9 - _ in document ids, so a merchant
    SKU like "SHIRT/RED/L" has to be reshaped before it can be an id."""
    s = re.sub(r"[^a-zA-Z0-9_-]+", "-", str(value)).strip("-")
    return s[:64].strip("-")


def generate_ids(titles: list[str]) -> list[str]:
    """Stable ids from titles; duplicates get -2, -3 ... suffixes.

    slugify() keeps CJK characters (useful for readability elsewhere), but
    Meilisearch document ids only allow a-z A-Z 0-9 _ -, so the slug is run
    through sanitize_id() as well. A title made entirely of CJK characters
    (or other non-ASCII text) sanitizes to "" and falls back to item-N.
    """
    seen: dict[str, int] = {}
    ids: list[str] = []
    for i, title in enumerate(titles, start=1):
        base = sanitize_id(slugify(title)) or f"item-{i}"
        seen[base] = seen.get(base, 0) + 1
        ids.append(base if seen[base] == 1 else f"{base}-{seen[base]}")
    return ids


def strip_html(text: str) -> str:
    """Shopify's Body (HTML) is raw markup — never index the tags."""
    if not text:
        return ""
    no_tags = re.sub(r"<[^>]+>", " ", str(text))
    return re.sub(r"\s+", " ", html.unescape(no_tags)).strip()


def coerce_price(value):
    """Numbers for real prices, original string when it isn't one."""
    if value is None or value == "":
        return ""
    if isinstance(value, (int, float)):
        return float(value)
    cleaned = re.sub(r"[^0-9.\-]", "", str(value))
    try:
        return float(cleaned)
    except ValueError:
        return value


def build_documents(rows: list[dict], mapping: dict[str, str | None]) -> list[dict]:
    """Build documents from a confirmed mapping, dropping unmapped columns."""
    if not mapping.get("title"):
        raise ValueError("A column must be mapped to 'title'.")

    available = set(rows[0].keys()) if rows else set()
    for target, source in mapping.items():
        if source and available and source not in available:
            raise ValueError(f"Column '{source}' is not in the uploaded file.")

    titles = [str(r.get(mapping["title"], "") or "") for r in rows]
    id_source = mapping.get("id")
    if id_source:
        # Sanitize raw id values and de-duplicate them
        raw_ids = [str(r.get(id_source, "") or "").strip() for r in rows]
        sanitized = [sanitize_id(rid) for rid in raw_ids]
        generated = generate_ids(titles)

        # De-duplicate sanitized ids with -2, -3 suffixes; fall back to generated
        seen: dict[str, int] = {}
        ids: list[str] = []
        for i in range(len(rows)):
            if sanitized[i]:
                base = sanitized[i]
                seen[base] = seen.get(base, 0) + 1
                ids.append(base if seen[base] == 1 else f"{base}-{seen[base]}")
            else:
                ids.append(generated[i])
    else:
        ids = generate_ids(titles)

    docs = []
    for i, row in enumerate(rows):
        doc: dict = {"id": ids[i]}
        for target in TARGET_FIELDS:
            if target == "id":
                continue
            source = mapping.get(target)
            value = row.get(source, "") if source else ""
            if value is None:
                value = ""
            if target == "description":
                value = strip_html(value)
            elif target == "price":
                value = coerce_price(value)
            else:
                value = str(value) if value != "" else ""
            doc[target] = value
        docs.append(doc)
    return docs
