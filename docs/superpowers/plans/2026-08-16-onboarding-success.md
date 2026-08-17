# Onboarding Success Pack Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a real merchant's first hour succeed — any product export uploads after a one-click column confirmation, and after pasting the snippet the merchant gets a definitive answer about whether it works.

**Architecture:** Ingestion splits into a pure mapping module (`services/ingestion/mapping.py`) plus a two-call route flow (`/ingest/preview` then `/ingest/upload` with an optional `mapping` field). Installation detection adds a `WidgetPing` upsert table fed by a widget mount ping and by `/search`, read back through `/tenant/install-status`. The developer handoff is a frontend-only `mailto:`.

**Tech Stack:** FastAPI, SQLAlchemy 2 async, pandas (already a dependency), Next.js 16 + Tailwind 4, TypeScript widget + esbuild, pytest, node:test.

**Spec:** `docs/superpowers/specs/2026-08-16-onboarding-success-design.md`

## Global Constraints

- Backend tests: `cd backend && poetry run pytest` (asyncio_mode=auto; existing `client` / `registered` conftest fixtures). Widget: `cd widget && npm test` and `npm run check`. Frontend: `cd frontend && npm run build`.
- Target fields, exact names and order: `id`, `title`, `description`, `price`, `category`, `brand`, `tags`, `image_url`, `url`. `title` is the only mandatory mapping.
- Generated ids: slugify the mapped title — lowercase, non-alphanumerics collapsed to `-`, leading/trailing `-` stripped, truncated to 64 chars; duplicates within one file get `-2`, `-3` … suffixes. Empty/unslugifiable titles fall back to `item-<row index starting at 1>`.
- Origin normalization (used for both `website_url` and pings): take the host of the URL, lowercase it, strip a leading `www.`, drop port/path/scheme. `https://MyStore.com/shop` → `mystore.com`.
- `WidgetPing.kind` is exactly `"load"` or `"search"`. Verdicts are exactly `ok`, `wrong_domain`, `not_found`, `no_website`.
- Analytics must never break a merchant page: a missing Origin records `"unknown"`, and ping failures are swallowed with a printed warning.
- The legacy no-mapping upload path (a CSV that already has `id`/`title`) must keep working unchanged — existing tests cover it and must stay green.
- Widget: zero runtime dependencies, artifact rebuilt and committed at `backend/app/widget/polarbear-widget.js`, ≤ 15KB, `npm run check` clean.
- Frontend: Tailwind utilities only, no new npm packages, match the existing white / gray-border / `indigo-600` card style.
- YAGNI (out of scope): platform plan warnings, domain-locking search keys, mapping template library, multi-file upload, Shopify App.

---

### Task 1: Mapping module — guessing, id generation, document building

**Files:**
- Create: `backend/app/services/ingestion/mapping.py`
- Test: `backend/tests/test_mapping.py`

**Interfaces:**
- Produces:
  - `TARGET_FIELDS: list[str]` — the nine target names in spec order
  - `normalize_header(name: str) -> str`
  - `guess_mapping(columns: list[str]) -> dict[str, str | None]` — every target present as a key
  - `slugify(text: str) -> str`
  - `generate_ids(titles: list[str]) -> list[str]`
  - `strip_html(text: str) -> str`
  - `coerce_price(value) -> float | str`
  - `build_documents(rows: list[dict], mapping: dict[str, str | None]) -> list[dict]`

- [ ] **Step 1: Write the failing test**

`backend/tests/test_mapping.py`:

```python
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd backend && poetry run pytest tests/test_mapping.py -v`
Expected: FAIL — `ModuleNotFoundError: app.services.ingestion.mapping`.

- [ ] **Step 3: Implement the module**

`backend/app/services/ingestion/mapping.py`:

```python
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


def generate_ids(titles: list[str]) -> list[str]:
    """Stable ids from titles; duplicates get -2, -3 ... suffixes."""
    seen: dict[str, int] = {}
    ids: list[str] = []
    for i, title in enumerate(titles, start=1):
        base = slugify(title) or f"item-{i}"
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
        ids = [str(r.get(id_source, "") or "").strip() for r in rows]
        generated = generate_ids(titles)
        ids = [ids[i] or generated[i] for i in range(len(rows))]
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd backend && poetry run pytest tests/test_mapping.py -v`
Expected: PASS (7 tests).

- [ ] **Step 5: Commit**

```bash
git add backend/app/services/ingestion/mapping.py backend/tests/test_mapping.py
git commit -m "feat: column mapping module — guessing, id generation, document building"
```

---

### Task 2: Parser preview + `/ingest/preview` and mapped `/ingest/upload`

**Files:**
- Modify: `backend/app/services/ingestion/parser.py`
- Modify: `backend/app/api/routes/ingestion.py`
- Test: `backend/tests/test_ingest_mapping.py`

**Interfaces:**
- Consumes: `guess_mapping`, `build_documents`, `TARGET_FIELDS` (Task 1); `resolve_admin_tenant`, `HybridIndexer(str(tenant.id)).index_data(docs)` (existing).
- Produces:
  - `DataParser.read_rows(file_content: bytes, filename: str) -> tuple[list[str], list[dict]]` — (columns, rows), no required-column check
  - `POST /ingest/preview` → `{"columns": [...], "sample_rows": [...], "row_count": int, "guess": {...}}`
  - `POST /ingest/upload` — unchanged signature plus optional `mapping` form field (JSON string)

- [ ] **Step 1: Write the failing test**

`backend/tests/test_ingest_mapping.py`:

```python
import io
import json

SHOPIFY_CSV = (
    b"Handle,Title,Body (HTML),Vendor,Type,Tags,Variant SKU,Variant Price,Image Src\n"
    b"blue-mug,Blue Mug,<p>Ceramic <b>mug</b></p>,MyShop,Drinkware,\"mug,gift\","
    b"SKU-1,$12.00,https://ex.com/1.jpg\n"
    b"red-mug,Red Mug,<p>Second mug</p>,MyShop,Drinkware,\"mug\",SKU-2,$14.00,"
    b"https://ex.com/2.jpg\n"
)
PLAIN_CSV = b"Product Name,Price\nWool Socks,9.50\nWool Socks,9.50\n"


class RecordingIndexer:
    last = None

    def __init__(self, tenant_id, storage=None, meili_client=None):
        self.tenant_id = str(tenant_id)

    def index_data(self, docs):
        RecordingIndexer.last = docs


async def test_preview_guesses_shopify_columns(registered):
    client, token, _ = registered
    files = {"file": ("export.csv", io.BytesIO(SHOPIFY_CSV), "text/csv")}
    r = await client.post(
        "/ingest/preview", files=files, headers={"Authorization": f"Bearer {token}"}
    )
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["row_count"] == 2
    assert len(body["sample_rows"]) == 2
    assert body["columns"][0] == "Handle"
    assert body["guess"]["title"] == "Title"
    assert body["guess"]["price"] == "Variant Price"
    assert body["guess"]["image_url"] == "Image Src"


async def test_preview_requires_auth(client):
    files = {"file": ("export.csv", io.BytesIO(SHOPIFY_CSV), "text/csv")}
    assert (await client.post("/ingest/preview", files=files)).status_code == 401


async def test_preview_rejects_empty_file(registered):
    client, token, _ = registered
    files = {"file": ("empty.csv", io.BytesIO(b""), "text/csv")}
    r = await client.post(
        "/ingest/preview", files=files, headers={"Authorization": f"Bearer {token}"}
    )
    assert r.status_code == 400


async def test_upload_with_mapping_indexes_clean_documents(registered, monkeypatch):
    client, token, _ = registered
    from app.api.routes import ingestion

    monkeypatch.setattr(ingestion, "HybridIndexer", RecordingIndexer)
    mapping = {"id": "Handle", "title": "Title", "description": "Body (HTML)",
               "price": "Variant Price", "category": "Type", "brand": "Vendor",
               "tags": "Tags", "image_url": "Image Src", "url": None}
    files = {"file": ("export.csv", io.BytesIO(SHOPIFY_CSV), "text/csv")}
    r = await client.post(
        "/ingest/upload",
        files=files,
        data={"mapping": json.dumps(mapping)},
        headers={"Authorization": f"Bearer {token}"},
    )
    assert r.status_code == 200, r.text
    docs = RecordingIndexer.last
    assert [d["id"] for d in docs] == ["blue-mug", "red-mug"]
    assert docs[0]["title"] == "Blue Mug"
    assert "<" not in docs[0]["description"]
    assert docs[0]["price"] == 12.0
    assert "Vendor" not in docs[0]  # source columns dropped


async def test_upload_without_id_column_generates_ids(registered, monkeypatch):
    client, token, _ = registered
    from app.api.routes import ingestion

    monkeypatch.setattr(ingestion, "HybridIndexer", RecordingIndexer)
    mapping = {"title": "Product Name", "price": "Price"}
    files = {"file": ("plain.csv", io.BytesIO(PLAIN_CSV), "text/csv")}
    r = await client.post(
        "/ingest/upload",
        files=files,
        data={"mapping": json.dumps(mapping)},
        headers={"Authorization": f"Bearer {token}"},
    )
    assert r.status_code == 200, r.text
    assert [d["id"] for d in RecordingIndexer.last] == ["wool-socks", "wool-socks-2"]


async def test_upload_with_bad_mapping_is_400(registered, monkeypatch):
    client, token, _ = registered
    from app.api.routes import ingestion

    monkeypatch.setattr(ingestion, "HybridIndexer", RecordingIndexer)
    auth = {"Authorization": f"Bearer {token}"}

    files = {"file": ("plain.csv", io.BytesIO(PLAIN_CSV), "text/csv")}
    r = await client.post(
        "/ingest/upload", files=files,
        data={"mapping": json.dumps({"title": "Nope"})}, headers=auth,
    )
    assert r.status_code == 400

    files = {"file": ("plain.csv", io.BytesIO(PLAIN_CSV), "text/csv")}
    r = await client.post(
        "/ingest/upload", files=files,
        data={"mapping": json.dumps({"price": "Price"})}, headers=auth,
    )
    assert r.status_code == 400  # title unmapped
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd backend && poetry run pytest tests/test_ingest_mapping.py -v`
Expected: FAIL — `/ingest/preview` is 404 and `/ingest/upload` ignores `mapping`.

- [ ] **Step 3: Add `read_rows` to the parser**

Append to `backend/app/services/ingestion/parser.py` inside `class DataParser`:

```python
    @staticmethod
    def read_rows(file_content: bytes, filename: str) -> tuple[list, list]:
        """Read any CSV/Excel into (columns, rows) with no required-column check."""
        if filename.endswith('.csv'):
            df = pd.read_csv(io.BytesIO(file_content))
        elif filename.endswith(('.xls', '.xlsx')):
            df = pd.read_excel(io.BytesIO(file_content))
        else:
            raise ValueError("Unsupported file format. Please upload CSV or Excel.")

        columns = [str(c) for c in df.columns]
        duplicates = {c for c in columns if columns.count(c) > 1}
        if duplicates:
            raise ValueError(f"Duplicate column names: {', '.join(sorted(duplicates))}")

        df = df.fillna('')
        return columns, df.to_dict(orient='records')
```

- [ ] **Step 4: Rewrite the ingestion route**

Replace `backend/app/api/routes/ingestion.py`:

```python
import json

from fastapi import APIRouter, Depends, File, Form, HTTPException, UploadFile

from app.core.tenancy import resolve_admin_tenant
from app.models import Tenant
from app.services.ingestion.mapping import build_documents, guess_mapping
from app.services.ingestion.parser import DataParser
from app.services.search.indexer import HybridIndexer

router = APIRouter()

SUPPORTED = (".csv", ".xls", ".xlsx")


def _read(file: UploadFile, content: bytes):
    if not file.filename.endswith(SUPPORTED):
        raise HTTPException(status_code=400, detail="Only CSV and Excel are supported.")
    try:
        return DataParser.read_rows(content, file.filename)
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))
    except Exception:
        raise HTTPException(
            status_code=400, detail="File is empty or could not be parsed."
        )


@router.post("/preview")
async def preview_file(
    file: UploadFile = File(...),
    tenant: Tenant = Depends(resolve_admin_tenant),
):
    """Read a file's columns and a few rows so the merchant can confirm mapping."""
    columns, rows = _read(file, await file.read())
    if not rows:
        raise HTTPException(status_code=400, detail="File is empty or could not be parsed.")
    return {
        "columns": columns,
        "sample_rows": rows[:3],
        "row_count": len(rows),
        "guess": guess_mapping(columns),
    }


@router.post("/upload")
async def upload_file(
    file: UploadFile = File(...),
    mapping: str | None = Form(default=None),
    tenant: Tenant = Depends(resolve_admin_tenant),
):
    """Index a product file. With `mapping`, columns are translated first;
    without it, the file must already use PolarBear's own column names."""
    content = await file.read()

    if mapping:
        try:
            mapping_dict = json.loads(mapping)
        except json.JSONDecodeError:
            raise HTTPException(status_code=400, detail="mapping must be valid JSON.")
        columns, rows = _read(file, content)
        if not rows:
            raise HTTPException(status_code=400, detail="File is empty or could not be parsed.")
        try:
            documents = build_documents(rows, mapping_dict)
        except ValueError as e:
            raise HTTPException(status_code=400, detail=str(e))
    else:
        if not file.filename.endswith(SUPPORTED):
            raise HTTPException(status_code=400, detail="Only CSV and Excel are supported.")
        try:
            documents = DataParser.parse_file(content, file.filename)
        except ValueError as e:
            raise HTTPException(status_code=400, detail=str(e))

    if not documents:
        raise HTTPException(status_code=400, detail="File is empty or could not be parsed.")

    try:
        HybridIndexer(str(tenant.id)).index_data(documents)
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

    return {
        "status": "success",
        "message": f"Successfully processed {len(documents)} documents.",
        "filename": file.filename,
    }
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd backend && poetry run pytest tests/test_ingest_mapping.py tests/test_admin_routes.py -v`
Expected: all PASS — the new mapping tests and the legacy no-mapping regression tests.

- [ ] **Step 6: Commit**

```bash
git add backend/app/services/ingestion/parser.py backend/app/api/routes/ingestion.py backend/tests/test_ingest_mapping.py
git commit -m "feat: /ingest/preview and mapping-aware upload so any export can be imported"
```

---

### Task 3: Mapping memory on the tenant

**Files:**
- Modify: `backend/app/models.py`
- Modify: `backend/app/api/routes/ingestion.py`
- Test: `backend/tests/test_mapping_memory.py`

**Interfaces:**
- Consumes: the routes from Task 2.
- Produces: `Tenant.column_mapping: Mapped[str | None]` (JSON string). `/ingest/upload` with a mapping saves it; `/ingest/preview` returns the saved mapping as `guess` when every saved source column exists in the new file.

- [ ] **Step 1: Write the failing test**

`backend/tests/test_mapping_memory.py`:

```python
import io
import json

SHOPIFY_CSV = (
    b"Handle,Title,Body (HTML),Variant Price\n"
    b"blue-mug,Blue Mug,<p>Mug</p>,$12.00\n"
)
OTHER_CSV = b"Product Name,Price\nWool Socks,9.50\n"


class NoopIndexer:
    def __init__(self, tenant_id, storage=None, meili_client=None):
        pass

    def index_data(self, docs):
        pass


async def test_saved_mapping_is_reused_for_a_matching_file(registered, monkeypatch):
    client, token, _ = registered
    from app.api.routes import ingestion

    monkeypatch.setattr(ingestion, "HybridIndexer", NoopIndexer)
    auth = {"Authorization": f"Bearer {token}"}
    mapping = {"id": "Handle", "title": "Title", "description": "Body (HTML)",
               "price": "Variant Price"}

    files = {"file": ("export.csv", io.BytesIO(SHOPIFY_CSV), "text/csv")}
    r = await client.post("/ingest/upload", files=files,
                          data={"mapping": json.dumps(mapping)}, headers=auth)
    assert r.status_code == 200, r.text

    files = {"file": ("export.csv", io.BytesIO(SHOPIFY_CSV), "text/csv")}
    r = await client.post("/ingest/preview", files=files, headers=auth)
    assert r.json()["guess"]["description"] == "Body (HTML)"


async def test_saved_mapping_ignored_when_columns_do_not_match(registered, monkeypatch):
    client, token, _ = registered
    from app.api.routes import ingestion

    monkeypatch.setattr(ingestion, "HybridIndexer", NoopIndexer)
    auth = {"Authorization": f"Bearer {token}"}
    mapping = {"id": "Handle", "title": "Title"}

    files = {"file": ("export.csv", io.BytesIO(SHOPIFY_CSV), "text/csv")}
    await client.post("/ingest/upload", files=files,
                      data={"mapping": json.dumps(mapping)}, headers=auth)

    files = {"file": ("other.csv", io.BytesIO(OTHER_CSV), "text/csv")}
    r = await client.post("/ingest/preview", files=files, headers=auth)
    # Falls back to guessing against the new file's own columns
    assert r.json()["guess"]["title"] == "Product Name"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd backend && poetry run pytest tests/test_mapping_memory.py -v`
Expected: FAIL — the saved mapping is not returned (guess comes from aliases only).

- [ ] **Step 3: Add the column to the Tenant model**

In `backend/app/models.py`, inside `class Tenant`, after `owner_user_id`:

```python
    column_mapping: Mapped[str | None] = mapped_column(Text, default=None)
```

Add `Text` to the existing `sqlalchemy` import line in that file.

- [ ] **Step 4: Save and reuse the mapping in the routes**

In `backend/app/api/routes/ingestion.py`, add these imports:

```python
from sqlalchemy.ext.asyncio import AsyncSession
from app.core.db import get_async_session
```

Give `preview_file` a session parameter and use the saved mapping when it fits:

```python
@router.post("/preview")
async def preview_file(
    file: UploadFile = File(...),
    tenant: Tenant = Depends(resolve_admin_tenant),
    session: AsyncSession = Depends(get_async_session),
):
    """Read a file's columns and a few rows so the merchant can confirm mapping."""
    columns, rows = _read(file, await file.read())
    if not rows:
        raise HTTPException(status_code=400, detail="File is empty or could not be parsed.")

    guess = guess_mapping(columns)
    if tenant.column_mapping:
        try:
            saved = json.loads(tenant.column_mapping)
        except json.JSONDecodeError:
            saved = None
        # Only reuse a remembered mapping when it still fits this file.
        if saved and all(v in columns for v in saved.values() if v):
            guess = {**guess, **saved}

    return {
        "columns": columns,
        "sample_rows": rows[:3],
        "row_count": len(rows),
        "guess": guess,
    }
```

In `upload_file`, add the same two parameters (`session: AsyncSession = Depends(get_async_session)`) and, immediately after `documents = build_documents(...)` succeeds, persist the mapping:

```python
        tenant.column_mapping = json.dumps(mapping_dict)
        session.add(tenant)
        await session.commit()
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd backend && poetry run pytest tests/test_mapping_memory.py tests/test_ingest_mapping.py -v`
Expected: all PASS.

- [ ] **Step 6: Commit**

```bash
git add backend/app/models.py backend/app/api/routes/ingestion.py backend/tests/test_mapping_memory.py
git commit -m "feat: remember a tenant's confirmed column mapping for repeat uploads"
```

---

### Task 4: WidgetPing model + origin helper + install-ping endpoint

**Files:**
- Modify: `backend/app/models.py`
- Create: `backend/app/services/origins.py`
- Modify: `backend/app/api/routes/analytics.py`, `backend/app/api/routes/search.py`
- Test: `backend/tests/test_install_ping.py`

**Interfaces:**
- Consumes: `resolve_search_tenant` (existing), `async_session_maker` (existing).
- Produces:
  - `WidgetPing` model — `id, tenant_id, origin, kind, first_seen, last_seen, count`, unique `(tenant_id, origin, kind)`
  - `app.services.origins`: `normalize_origin(value: str | None) -> str` (returns `"unknown"` when unusable), `origin_from_request(request) -> str`, `async record_ping(tenant_id, origin, kind) -> None`
  - `POST /analytics/install-ping` (search key or JWT) → `{"status": "ok"}`
  - `/search` also records a `"search"` ping

- [ ] **Step 1: Write the failing test**

`backend/tests/test_install_ping.py`:

```python
from sqlalchemy import select


def test_normalize_origin_strips_scheme_www_port_and_path():
    from app.services.origins import normalize_origin

    assert normalize_origin("https://MyStore.com/shop") == "mystore.com"
    assert normalize_origin("http://www.mystore.com:8080") == "mystore.com"
    assert normalize_origin("mystore.com") == "mystore.com"
    assert normalize_origin(None) == "unknown"
    assert normalize_origin("") == "unknown"


async def test_install_ping_records_and_dedupes(registered):
    client, token, _ = registered
    auth = {"Authorization": f"Bearer {token}"}
    key = (await client.get("/tenant/keys", headers=auth)).json()["search"]["key"]
    headers = {"X-PolarBear-Key": key, "Origin": "https://www.MyStore.com"}

    assert (await client.post("/analytics/install-ping", headers=headers)).status_code == 200
    assert (await client.post("/analytics/install-ping", headers=headers)).status_code == 200

    from app.core.db import async_session_maker
    from app.models import WidgetPing

    async with async_session_maker() as s:
        rows = (await s.execute(select(WidgetPing))).scalars().all()
        assert len(rows) == 1
        assert rows[0].origin == "mystore.com"
        assert rows[0].kind == "load"
        assert rows[0].count == 2


async def test_install_ping_without_origin_is_recorded_as_unknown(registered):
    client, token, _ = registered
    auth = {"Authorization": f"Bearer {token}"}
    key = (await client.get("/tenant/keys", headers=auth)).json()["search"]["key"]

    r = await client.post("/analytics/install-ping", headers={"X-PolarBear-Key": key})
    assert r.status_code == 200

    from app.core.db import async_session_maker
    from app.models import WidgetPing

    async with async_session_maker() as s:
        rows = (await s.execute(select(WidgetPing))).scalars().all()
        assert [r.origin for r in rows] == ["unknown"]


async def test_install_ping_rejects_bad_key(client):
    r = await client.post(
        "/analytics/install-ping", headers={"X-PolarBear-Key": "pb_search_bogus"}
    )
    assert r.status_code == 401
    assert (await client.post("/analytics/install-ping")).status_code == 401
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd backend && poetry run pytest tests/test_install_ping.py -v`
Expected: FAIL — `app.services.origins` missing and the endpoint is 404.

- [ ] **Step 3: Add the model**

In `backend/app/models.py`, append:

```python
class WidgetPing(Base):
    """One row per (tenant, origin, kind) — grows with domains, not traffic."""

    __tablename__ = "widget_pings"

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    tenant_id: Mapped[uuid.UUID] = mapped_column(index=True)
    origin: Mapped[str] = mapped_column(String(255))
    kind: Mapped[str] = mapped_column(String(10))  # "load" | "search"
    first_seen: Mapped[datetime] = mapped_column(DateTime, server_default=func.now())
    last_seen: Mapped[datetime] = mapped_column(DateTime, server_default=func.now())
    count: Mapped[int] = mapped_column(Integer, default=0)

    __table_args__ = (UniqueConstraint("tenant_id", "origin", "kind"),)
```

- [ ] **Step 4: Write the origins service**

`backend/app/services/origins.py`:

```python
"""Where a merchant's widget is actually running."""

import uuid
from datetime import datetime, timezone
from urllib.parse import urlparse

from sqlalchemy import select

from app.core.db import async_session_maker
from app.models import WidgetPing

UNKNOWN = "unknown"


def normalize_origin(value: str | None) -> str:
    """https://MyStore.com/shop -> mystore.com"""
    if not value:
        return UNKNOWN
    raw = str(value).strip()
    if "//" not in raw:
        raw = "//" + raw
    host = (urlparse(raw).hostname or "").lower()
    if host.startswith("www."):
        host = host[4:]
    return host or UNKNOWN


def origin_from_request(request) -> str:
    """Prefer the CORS Origin header; fall back to the Referer's host."""
    origin = request.headers.get("origin")
    if origin:
        return normalize_origin(origin)
    return normalize_origin(request.headers.get("referer"))


async def record_ping(tenant_id: uuid.UUID, origin: str, kind: str) -> None:
    """Upsert one (tenant, origin, kind) row. Never raises — statistics must
    not break a merchant's page."""
    try:
        async with async_session_maker() as session:
            row = (
                await session.execute(
                    select(WidgetPing).where(
                        WidgetPing.tenant_id == tenant_id,
                        WidgetPing.origin == origin,
                        WidgetPing.kind == kind,
                    )
                )
            ).scalar_one_or_none()
            now = datetime.now(timezone.utc).replace(tzinfo=None)
            if row is None:
                session.add(
                    WidgetPing(
                        tenant_id=tenant_id, origin=origin, kind=kind,
                        count=1, first_seen=now, last_seen=now,
                    )
                )
            else:
                row.count += 1
                row.last_seen = now
            await session.commit()
    except Exception as e:
        print(f"Failed to record widget ping: {e}")
```

- [ ] **Step 5: Add the endpoint and record search pings**

In `backend/app/api/routes/analytics.py` add:

```python
from fastapi import Request
from app.services.origins import origin_from_request, record_ping


@router.post("/install-ping")
async def install_ping(
    request: Request, tenant_id: uuid.UUID = Depends(resolve_search_tenant)
):
    """The widget calls this once when it mounts, so a merchant can confirm the
    install before any shopper has searched."""
    await record_ping(tenant_id, origin_from_request(request), "load")
    return {"status": "ok"}
```

In `backend/app/api/routes/search.py`, add `Request` to the fastapi import, import the helpers, add `request: Request` as the first parameter of the `search` function, and record alongside the existing log:

```python
    background_tasks.add_task(log_search, tenant_id, q, len(results))
    background_tasks.add_task(
        record_ping, tenant_id, origin_from_request(request), "search"
    )
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `cd backend && poetry run pytest tests/test_install_ping.py tests/test_search_route.py -v`
Expected: all PASS.

- [ ] **Step 7: Commit**

```bash
git add backend/app/models.py backend/app/services/origins.py backend/app/api/routes/analytics.py backend/app/api/routes/search.py backend/tests/test_install_ping.py
git commit -m "feat: widget install pings recorded per origin"
```

---

### Task 5: Website URL + `/tenant/install-status`

**Files:**
- Modify: `backend/app/models.py`, `backend/app/api/routes/tenant.py`
- Test: `backend/tests/test_install_status.py`

**Interfaces:**
- Consumes: `WidgetPing`, `normalize_origin` (Task 4); `get_current_tenant`, `get_async_session` (existing).
- Produces:
  - `Tenant.website_url: Mapped[str | None]` (normalized host)
  - `PUT /tenant/website` body `{"website_url": "https://MyStore.com/shop"}` → `{"website_url": "mystore.com"}`
  - `GET /tenant/install-status` → `{"website_url", "pings": [{origin, kind, last_seen, count}], "verdict"}` with verdict in `ok | wrong_domain | not_found | no_website`

- [ ] **Step 1: Write the failing test**

`backend/tests/test_install_status.py`:

```python
async def _key(client, token):
    r = await client.get("/tenant/keys", headers={"Authorization": f"Bearer {token}"})
    return r.json()["search"]["key"]


async def test_status_is_no_website_then_not_found(registered):
    client, token, _ = registered
    auth = {"Authorization": f"Bearer {token}"}

    r = await client.get("/tenant/install-status", headers=auth)
    assert r.status_code == 200
    assert r.json()["verdict"] == "no_website"

    r = await client.put(
        "/tenant/website", json={"website_url": "https://MyStore.com/shop"}, headers=auth
    )
    assert r.status_code == 200
    assert r.json()["website_url"] == "mystore.com"

    r = await client.get("/tenant/install-status", headers=auth)
    assert r.json()["verdict"] == "not_found"


async def test_status_ok_after_matching_ping(registered):
    client, token, _ = registered
    auth = {"Authorization": f"Bearer {token}"}
    await client.put("/tenant/website", json={"website_url": "mystore.com"}, headers=auth)
    key = await _key(client, token)

    await client.post(
        "/analytics/install-ping",
        headers={"X-PolarBear-Key": key, "Origin": "https://www.mystore.com"},
    )

    body = (await client.get("/tenant/install-status", headers=auth)).json()
    assert body["verdict"] == "ok"
    assert body["pings"][0]["origin"] == "mystore.com"
    assert body["pings"][0]["kind"] == "load"


async def test_status_wrong_domain(registered):
    client, token, _ = registered
    auth = {"Authorization": f"Bearer {token}"}
    await client.put("/tenant/website", json={"website_url": "mystore.com"}, headers=auth)
    key = await _key(client, token)

    await client.post(
        "/analytics/install-ping",
        headers={"X-PolarBear-Key": key, "Origin": "https://staging.othersite.com"},
    )

    assert (await client.get("/tenant/install-status", headers=auth)).json()[
        "verdict"
    ] == "wrong_domain"


async def test_status_requires_auth(client):
    assert (await client.get("/tenant/install-status")).status_code == 401
    assert (await client.put("/tenant/website", json={"website_url": "x.com"})).status_code == 401
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd backend && poetry run pytest tests/test_install_status.py -v`
Expected: FAIL — both routes are 404.

- [ ] **Step 3: Add the tenant column**

In `backend/app/models.py`, inside `class Tenant`, after `column_mapping`:

```python
    website_url: Mapped[str | None] = mapped_column(String(255), default=None)
```

- [ ] **Step 4: Implement the routes**

Append to `backend/app/api/routes/tenant.py` (add `from pydantic import BaseModel`, `from app.models import WidgetPing`, and `from app.services.origins import normalize_origin` to the imports):

```python
class WebsiteUpdate(BaseModel):
    website_url: str


@router.put("/website")
async def set_website(
    payload: WebsiteUpdate,
    tenant: Tenant = Depends(get_current_tenant),
    session: AsyncSession = Depends(get_async_session),
):
    """Store the merchant's site as a bare host so ping comparisons are robust."""
    tenant.website_url = normalize_origin(payload.website_url)
    session.add(tenant)
    await session.commit()
    return {"website_url": tenant.website_url}


@router.get("/install-status")
async def install_status(
    tenant: Tenant = Depends(get_current_tenant),
    session: AsyncSession = Depends(get_async_session),
):
    """Did the widget actually load on the merchant's site?"""
    rows = (
        await session.execute(
            select(WidgetPing).where(WidgetPing.tenant_id == tenant.id)
        )
    ).scalars().all()

    pings = [
        {
            "origin": p.origin,
            "kind": p.kind,
            "count": p.count,
            "last_seen": p.last_seen.isoformat() if p.last_seen else None,
        }
        for p in rows
    ]

    loads = [p for p in rows if p.kind == "load"]
    if not tenant.website_url:
        verdict = "no_website"
    elif not loads:
        verdict = "not_found"
    elif any(p.origin == tenant.website_url for p in loads):
        verdict = "ok"
    else:
        verdict = "wrong_domain"

    return {"website_url": tenant.website_url, "pings": pings, "verdict": verdict}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd backend && poetry run pytest tests/test_install_status.py -v` then `poetry run pytest`
Expected: all PASS.

- [ ] **Step 6: Commit**

```bash
git add backend/app/models.py backend/app/api/routes/tenant.py backend/tests/test_install_status.py
git commit -m "feat: tenant website URL and install-status verdicts"
```

---

### Task 6: Widget mount ping

**Files:**
- Modify: `widget/src/api.ts`, `widget/src/index.ts`
- Modify: `widget/test/api.test.mjs`
- Regenerate + commit: `backend/app/widget/polarbear-widget.js`

**Interfaces:**
- Consumes: `WidgetConfig {api, key}` (existing), `POST /analytics/install-ping` (Task 4).
- Produces: `sendInstallPing(cfg: WidgetConfig, fetchFn?): void` exported from `api.ts`, called once from the bootstrap after a successful mount.

- [ ] **Step 1: Write the failing test**

Append to `widget/test/api.test.mjs`:

```javascript
test('install ping posts once with the key and never throws', async () => {
  const { sendInstallPing } = await import('./.api.build.mjs');
  const calls = [];
  sendInstallPing({ api: 'http://x', key: 'k' }, (url, init) => {
    calls.push({ url, init });
    return Promise.resolve({ ok: true });
  });
  assert.equal(calls.length, 1);
  assert.match(calls[0].url, /\/analytics\/install-ping$/);
  assert.equal(calls[0].init.headers['X-PolarBear-Key'], 'k');

  // a broken fetch must not propagate
  sendInstallPing({ api: 'http://x', key: 'k' }, () => { throw new Error('boom'); });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd widget && npm test`
Expected: FAIL — `sendInstallPing` is not exported.

- [ ] **Step 3: Implement the ping**

Append to `widget/src/api.ts`:

```typescript
/** Tell the backend the widget mounted, so the merchant can verify the install
 *  before any shopper has searched. Fire-and-forget: never throws. */
export function sendInstallPing(
  cfg: WidgetConfig,
  fetchFn: typeof fetch = fetch.bind(globalThis)
): void {
  try {
    const p = fetchFn(`${cfg.api}/analytics/install-ping`, {
      method: 'POST',
      keepalive: true,
      headers: { 'X-PolarBear-Key': cfg.key },
    });
    if (p && typeof (p as Promise<unknown>).catch === 'function') {
      (p as Promise<unknown>).catch(() => {});
    }
  } catch {
    /* never break the merchant page */
  }
}
```

- [ ] **Step 4: Call it from the bootstrap**

In `widget/src/index.ts`, add `sendInstallPing` to the import from `./api` (create the import line `import { sendInstallPing } from './api';` if the file has none), and call it as the last statement inside `mount()`, right after `mountSearchBox(shadow, { api, key })`:

```typescript
    mountSearchBox(shadow, { api, key });
    sendInstallPing({ api, key });
```

- [ ] **Step 5: Rebuild and verify**

Run: `cd widget && npm run build && npm test && npm run check`
Expected: build succeeds, all node tests pass (7), `npm run check` exits 0. Confirm size:

```bash
node -e "const s=require('fs').statSync('../backend/app/widget/polarbear-widget.js').size; console.log(s+' bytes'); process.exit(s<=15000?0:1)"
```

- [ ] **Step 6: Commit**

```bash
git add widget/ backend/app/widget/polarbear-widget.js
git commit -m "feat(widget): ping the backend on mount so installs can be verified"
```

---

### Task 7: Upload page — mapping screen

**Files:**
- Modify: `frontend/src/app/upload/page.tsx`

**Interfaces:**
- Consumes: `POST /ingest/preview`, `POST /ingest/upload` with `mapping` (Tasks 2–3); `authFetch`, `useRequireAuth` (existing).

- [ ] **Step 1: Rewrite the upload page**

Replace `frontend/src/app/upload/page.tsx`:

```tsx
'use client';

import { useState } from 'react';
import { authFetch, useRequireAuth } from '../../lib/api';

const TARGETS = [
  { key: 'title', label: 'Product name', required: true },
  { key: 'description', label: 'Description' },
  { key: 'price', label: 'Price' },
  { key: 'id', label: 'Product ID / SKU' },
  { key: 'category', label: 'Category' },
  { key: 'brand', label: 'Brand' },
  { key: 'tags', label: 'Tags' },
  { key: 'image_url', label: 'Image URL' },
  { key: 'url', label: 'Product page URL' },
];

interface Preview {
  columns: string[];
  sample_rows: Record<string, string>[];
  row_count: number;
  guess: Record<string, string | null>;
}

export default function UploadPage() {
  useRequireAuth();
  const [file, setFile] = useState<File | null>(null);
  const [preview, setPreview] = useState<Preview | null>(null);
  const [mapping, setMapping] = useState<Record<string, string>>({});
  const [status, setStatus] = useState('');
  const [busy, setBusy] = useState(false);

  const reset = () => {
    setFile(null);
    setPreview(null);
    setMapping({});
  };

  const handleFileChange = async (e: React.ChangeEvent<HTMLInputElement>) => {
    const f = e.target.files?.[0];
    if (!f) return;
    setFile(f);
    setStatus('');
    setBusy(true);
    try {
      const form = new FormData();
      form.append('file', f);
      const res = await authFetch('/ingest/preview', { method: 'POST', body: form });
      const data = await res.json();
      if (!res.ok) {
        setStatus(`Error: ${data.detail}`);
        setFile(null);
        return;
      }
      setPreview(data);
      const initial: Record<string, string> = {};
      TARGETS.forEach((t) => {
        const g = data.guess[t.key];
        if (g) initial[t.key] = g;
      });
      setMapping(initial);
    } catch {
      setStatus('Error: Failed to connect to server.');
      setFile(null);
    } finally {
      setBusy(false);
    }
  };

  const handleImport = async () => {
    if (!file) return;
    setBusy(true);
    setStatus('Importing and indexing…');
    try {
      const form = new FormData();
      form.append('file', file);
      form.append(
        'mapping',
        JSON.stringify(
          Object.fromEntries(TARGETS.map((t) => [t.key, mapping[t.key] || null]))
        )
      );
      const res = await authFetch('/ingest/upload', { method: 'POST', body: form });
      const data = await res.json();
      if (res.ok) {
        setStatus(`Success: ${data.message}`);
        reset();
      } else {
        setStatus(`Error: ${data.detail}`);
      }
    } catch {
      setStatus('Error: Failed to connect to server.');
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="min-h-screen bg-gray-50 p-8">
      <div className="max-w-2xl mx-auto bg-white rounded-xl shadow-md p-6">
        <div className="uppercase tracking-wide text-sm text-indigo-500 font-semibold mb-2">
          Data Ingestion
        </div>
        <h1 className="text-lg font-medium text-black mb-6">Upload Product Catalog</h1>

        {!preview && (
          <>
            <div className="bg-blue-50 p-4 rounded-lg text-sm text-blue-800 mb-6">
              <p className="font-medium mb-1">Bring the file you already have.</p>
              <p>
                Export from Shopify, WooCommerce, or your own spreadsheet — we read the
                columns and let you confirm what they mean. Only a product name is
                required.
              </p>
            </div>

            <label className="block text-gray-700 text-sm font-bold mb-2" htmlFor="file-upload">
              Select CSV or Excel file
            </label>
            <input
              type="file"
              id="file-upload"
              accept=".csv, .xls, .xlsx"
              onChange={handleFileChange}
              disabled={busy}
              className="block w-full text-sm text-gray-500
                file:mr-4 file:py-2 file:px-4 file:rounded-full file:border-0
                file:text-sm file:font-semibold file:bg-indigo-50 file:text-indigo-700
                hover:file:bg-indigo-100"
            />
            {busy && <p className="mt-3 text-sm text-gray-500">Reading your file…</p>}
          </>
        )}

        {preview && (
          <>
            <div className="mb-4 text-sm text-gray-600">
              <span className="font-medium text-gray-900">{file?.name}</span> ·{' '}
              {preview.row_count} rows · {preview.columns.length} columns
            </div>

            <h2 className="text-sm font-semibold text-gray-900 mb-1">
              Confirm what each column means
            </h2>
            <p className="text-xs text-gray-500 mb-4">
              We guessed from your column names. Change anything that looks wrong.
            </p>

            <div className="space-y-3 mb-5">
              {TARGETS.map((t) => (
                <div key={t.key} className="flex items-center gap-3">
                  <label className="w-40 text-sm text-gray-700" htmlFor={`map-${t.key}`}>
                    {t.label}
                    {t.required && <span className="text-indigo-600"> *</span>}
                  </label>
                  <select
                    id={`map-${t.key}`}
                    value={mapping[t.key] || ''}
                    onChange={(e) =>
                      setMapping({ ...mapping, [t.key]: e.target.value })
                    }
                    className="flex-1 border border-gray-300 rounded-md px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-indigo-500"
                  >
                    <option value="">— not in my file —</option>
                    {preview.columns.map((c) => (
                      <option key={c} value={c}>
                        {c}
                      </option>
                    ))}
                  </select>
                </div>
              ))}
            </div>

            {!mapping.id && (
              <div className="mb-5 p-3 rounded bg-amber-50 text-amber-800 text-xs">
                No product ID column selected — we&apos;ll number your products
                automatically. If you rename a product later, it will be added as a new
                one rather than updating the old entry.
              </div>
            )}

            <div className="mb-5">
              <h3 className="text-xs font-semibold text-gray-700 mb-2">
                Preview of the first rows
              </h3>
              <div className="overflow-x-auto border border-gray-200 rounded">
                <table className="w-full text-xs">
                  <thead className="bg-gray-50 text-gray-500">
                    <tr>
                      {TARGETS.filter((t) => mapping[t.key]).map((t) => (
                        <th key={t.key} className="px-3 py-2 text-left font-medium">
                          {t.label}
                        </th>
                      ))}
                    </tr>
                  </thead>
                  <tbody className="divide-y divide-gray-100">
                    {preview.sample_rows.map((row, i) => (
                      <tr key={i}>
                        {TARGETS.filter((t) => mapping[t.key]).map((t) => (
                          <td key={t.key} className="px-3 py-2 text-gray-700 truncate max-w-[180px]">
                            {String(row[mapping[t.key]] ?? '')}
                          </td>
                        ))}
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            </div>

            <div className="flex gap-3">
              <button
                onClick={handleImport}
                disabled={busy || !mapping.title}
                className={`flex-1 py-2 px-4 rounded-md text-sm font-medium text-white ${
                  busy || !mapping.title
                    ? 'bg-gray-400 cursor-not-allowed'
                    : 'bg-indigo-600 hover:bg-indigo-700'
                }`}
              >
                {busy ? 'Importing…' : `Import ${preview.row_count} products`}
              </button>
              <button
                onClick={reset}
                disabled={busy}
                className="py-2 px-4 rounded-md text-sm font-medium border border-gray-300 text-gray-700 hover:bg-gray-50"
              >
                Choose a different file
              </button>
            </div>
          </>
        )}

        {status && (
          <div
            className={`mt-4 p-3 rounded text-sm ${
              status.startsWith('Error')
                ? 'bg-red-100 text-red-700'
                : 'bg-green-100 text-green-700'
            }`}
          >
            {status}
          </div>
        )}
      </div>
    </div>
  );
}
```

- [ ] **Step 2: Verify build**

Run: `cd frontend && npm run build`
Expected: clean build.

- [ ] **Step 3: Manual check**

With backend + frontend running and signed in: pick a Shopify-style CSV → mapping screen appears with guesses filled → preview table shows real values → Import succeeds. Pick a CSV with only `Product Name,Price` → the amber auto-numbering notice appears → import succeeds.

- [ ] **Step 4: Commit**

```bash
git add frontend/src/app/upload/page.tsx
git commit -m "feat(frontend): confirm-your-columns upload flow"
```

---

### Task 8: Settings — website URL, install check, developer handoff

**Files:**
- Modify: `frontend/src/app/settings/page.tsx`

**Interfaces:**
- Consumes: `PUT /tenant/website`, `GET /tenant/install-status` (Task 5), `GET /tenant/snippet` (existing); `authFetch`, `useRequireAuth` (existing).

- [ ] **Step 1: Add the developer handoff link to the embed section**

In `frontend/src/app/settings/page.tsx`, inside `EmbedSection`, directly after the snippet `<pre>`/copy-button block's closing `</div>`, add:

```tsx
      <p className="mt-3 text-xs text-gray-500">
        Someone else maintains your site?{' '}
        <a
          className="text-indigo-600 hover:underline"
          href={`mailto:?subject=${encodeURIComponent(
            'Please add our product search box to the website'
          )}&body=${encodeURIComponent(
            `Hi,\n\nPlease add our product search to the website.\n\n` +
              `Paste these two lines where the search box should appear:\n\n${snippet}\n\n` +
              `The first line is the spot the box renders in; the second loads it.\n` +
              `Platform-by-platform instructions: https://github.com/dukesky/PolarBear/blob/main/docs/INTEGRATION.md\n\n` +
              `Thanks!`
          )}`}
        >
          Email these instructions to them
        </a>
      </p>
```

- [ ] **Step 2: Add the InstallCheck component**

Render `<InstallCheck />` immediately after `<EmbedSection />` inside the Settings card, and append this component to the bottom of the file:

```tsx
interface StatusResponse {
  website_url: string | null;
  pings: { origin: string; kind: string; count: number; last_seen: string | null }[];
  verdict: 'ok' | 'wrong_domain' | 'not_found' | 'no_website';
}

function InstallCheck() {
  const [website, setWebsite] = useState('');
  const [saved, setSaved] = useState<string | null>(null);
  const [status, setStatus] = useState<StatusResponse | null>(null);
  const [checking, setChecking] = useState(false);

  const load = () => {
    authFetch('/tenant/install-status')
      .then((r) => (r.ok ? r.json() : null))
      .then((d: StatusResponse | null) => {
        if (!d) return;
        setStatus(d);
        setSaved(d.website_url);
        if (d.website_url) setWebsite(d.website_url);
      })
      .catch(() => {});
  };

  useEffect(load, []);

  const saveWebsite = async (e: React.FormEvent) => {
    e.preventDefault();
    const r = await authFetch('/tenant/website', {
      method: 'PUT',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ website_url: website }),
    });
    if (r.ok) {
      const d = await r.json();
      setSaved(d.website_url);
      setWebsite(d.website_url);
      load();
    }
  };

  const check = async () => {
    setChecking(true);
    await new Promise((r) => setTimeout(r, 400));
    load();
    setChecking(false);
  };

  const loadPing = status?.pings.find((p) => p.kind === 'load');
  const searchPing = status?.pings.find((p) => p.kind === 'search');

  return (
    <div className="mt-6 p-4 border border-gray-200 rounded-lg">
      <h2 className="text-sm font-semibold text-gray-900 mb-1">Check your installation</h2>
      <p className="text-xs text-gray-500 mb-3">
        After pasting the code into your site, confirm it&apos;s live here.
      </p>

      <form onSubmit={saveWebsite} className="flex gap-2 mb-3">
        <input
          value={website}
          onChange={(e) => setWebsite(e.target.value)}
          placeholder="yourstore.com"
          className="flex-1 border border-gray-300 rounded-md px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-indigo-500"
        />
        <button
          type="submit"
          className="text-xs font-medium px-3 py-2 rounded bg-indigo-50 text-indigo-700 hover:bg-indigo-100"
        >
          {saved ? 'Update' : 'Save'}
        </button>
      </form>

      <button
        onClick={check}
        disabled={checking}
        className={`text-sm font-medium px-4 py-2 rounded-md text-white ${
          checking ? 'bg-gray-400' : 'bg-indigo-600 hover:bg-indigo-700'
        }`}
      >
        {checking ? 'Checking…' : 'Check my installation'}
      </button>

      {status?.verdict === 'ok' && (
        <div className="mt-3 p-3 rounded bg-green-50 text-green-800 text-sm">
          Working — the search box loaded on <strong>{loadPing?.origin}</strong>.
          {searchPing
            ? ` It has answered ${searchPing.count} searches.`
            : ' No shopper has searched yet.'}
        </div>
      )}
      {status?.verdict === 'wrong_domain' && (
        <div className="mt-3 p-3 rounded bg-amber-50 text-amber-800 text-sm">
          Found the search box on <strong>{loadPing?.origin}</strong>, but not on{' '}
          <strong>{saved}</strong>. If that&apos;s a staging site, you&apos;re fine —
          otherwise update the address above or check which site you pasted the code
          into.
        </div>
      )}
      {status?.verdict === 'not_found' && (
        <div className="mt-3 p-3 rounded bg-red-50 text-red-700 text-sm">
          <p className="font-medium mb-1">No sign of the search box yet.</p>
          <ul className="list-disc list-inside space-y-0.5 text-xs">
            <li>Did you save and publish the page after pasting?</li>
            <li>Is the code on a live page rather than a draft?</li>
            <li>Did you paste both lines, including the one starting with &lt;div&gt;?</li>
            <li>Open your site once — the check only sees pages that have loaded.</li>
          </ul>
        </div>
      )}
      {status?.verdict === 'no_website' && (
        <div className="mt-3 p-3 rounded bg-gray-50 text-gray-600 text-sm">
          Add your website address above so we can tell you whether the box is live on
          it.
        </div>
      )}
    </div>
  );
}
```

- [ ] **Step 3: Verify build**

Run: `cd frontend && npm run build`
Expected: clean build.

- [ ] **Step 4: Manual check**

Signed in: save `localhost` as the website, load the demo storefront with your search key, press **Check my installation** → green "Working". Change the saved website to `example.com` and re-check → amber "wrong domain".

- [ ] **Step 5: Commit**

```bash
git add frontend/src/app/settings/page.tsx
git commit -m "feat(frontend): installation self-check and developer handoff in Settings"
```

---

### Task 9: Home page status line + docs

**Files:**
- Create: `frontend/src/components/InstallStatusLine.tsx`
- Modify: `frontend/src/app/page.tsx`
- Modify: `docs/INTEGRATION.md`

**Interfaces:**
- Consumes: `GET /tenant/install-status` (Task 5), `getToken`, `authFetch` (existing).
- Produces: `InstallStatusLine` default-exported client component.

**Note:** `frontend/src/app/page.tsx` is currently a server component (no `'use client'` directive) and must stay one — the status line goes in its own client component so the home page keeps rendering statically.

- [ ] **Step 1: Create the status line client component**

`frontend/src/components/InstallStatusLine.tsx`:

```tsx
'use client';

import { useEffect, useState } from 'react';
import { authFetch, getToken } from '../lib/api';

export default function InstallStatusLine() {
  const [verdict, setVerdict] = useState<string | null>(null);
  const [origin, setOrigin] = useState<string | null>(null);

  useEffect(() => {
    if (!getToken()) return;
    authFetch('/tenant/install-status')
      .then((r) => (r.ok ? r.json() : null))
      .then((d) => {
        if (!d) return;
        setVerdict(d.verdict);
        setOrigin(d.pings.find((p: { kind: string }) => p.kind === 'load')?.origin ?? null);
      })
      .catch(() => {});
  }, []);

  if (!verdict) return null;

  const live = verdict === 'ok';
  return (
    <p className="mt-6 text-sm text-gray-500">
      <span
        className={`inline-block w-2 h-2 rounded-full mr-2 align-middle ${
          live ? 'bg-green-500' : 'bg-gray-300'
        }`}
      />
      {live ? (
        <>Search live on <span className="font-medium text-gray-700">{origin}</span></>
      ) : (
        <>
          Search not installed yet ·{' '}
          <a href="/settings" className="text-indigo-600 hover:underline">
            finish setup
          </a>
        </>
      )}
    </p>
  );
}
```

- [ ] **Step 2: Render it on the home page**

In `frontend/src/app/page.tsx`, add the import at the top alongside the existing `next/link` and `next/image` imports:

```tsx
import InstallStatusLine from "../components/InstallStatusLine";
```

Then render `<InstallStatusLine />` immediately after the closing tag of the div containing the "Start Searching" / "Upload Data" buttons.

- [ ] **Step 3: Document the new upload flow**

In `docs/INTEGRATION.md`, replace the paragraph under "## Step 1 — Upload your products" that begins "Go to **Upload** and select a CSV" with:

```markdown
Go to **Upload** and select a CSV or Excel file — including a raw export from
Shopify, WooCommerce, or Square, or your own spreadsheet. PolarBear reads your
column names, guesses what each one means, and shows you a confirmation screen
before importing anything.

Only one column is truly required: **the product name**. Everything else is
optional and improves results:
```

Then, immediately after the column table, add:

```markdown
**No product ID column?** That's fine — PolarBear numbers your products
automatically from their names. One consequence worth knowing: if you rename a
product and re-upload, it arrives as a new product rather than an update to the
old one.

**After you paste the snippet**, come back to **Settings → Check your
installation**. Enter your website address and press the button: it tells you
whether the search box actually loaded on your site, and what to check if it
didn't.
```

- [ ] **Step 4: Verify build**

Run: `cd frontend && npm run build`
Expected: clean build.

- [ ] **Step 5: Commit**

```bash
git add frontend/src/components/InstallStatusLine.tsx frontend/src/app/page.tsx docs/INTEGRATION.md
git commit -m "feat(frontend): home page install status; document the mapping flow"
```

---

## Final Verification (whole plan)

- [ ] `cd backend && poetry run pytest` — all green (mapping, ingest mapping, mapping memory, install ping, install status, plus every pre-existing test)
- [ ] `cd widget && npm run build && npm test && npm run check` — 7 node tests, artifact fresh and ≤ 15KB
- [ ] `cd frontend && npm run build` — clean
- [ ] **Acceptance gate**: upload the exact Shopify-format CSV that fails on production today (`Handle,Title,Body (HTML),Vendor,Type,Tags,Variant SKU,Variant Price,Image Src`) through the UI with zero manual editing — mapping is pre-filled, import succeeds, and a search returns those products with tag-free descriptions
- [ ] **Acceptance gate**: with the demo storefront open and using the tenant's search key, Settings → Check my installation reports `ok` for the matching domain and `wrong_domain` after changing the saved website
- [ ] `git log --oneline` shows one commit per task
