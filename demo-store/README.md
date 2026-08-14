# Corner Hardware — demo storefront

A believable little store page for testing PolarBear end to end, the way a real
merchant would: upload a catalog, paste the embed snippet, then shop your own
store.

It's a hardware store on purpose. Hardware shoppers describe problems ("my
faucet drips") instead of naming parts ("faucet washer assortment"), which is
exactly where semantic search beats keyword search — you can see the difference
in one query.

## Run it

```bash
cd demo-store
python3 -m http.server 4173
```

Open <http://localhost:4173>.

## Use it as a merchant

1. Register at your PolarBear dashboard
   (hosted: <https://polarbear-frontend-399780699896.us-central1.run.app>).
2. **Upload** → select `demo-store/products.csv` (18 products).
3. **Settings** → copy your **Public Search Key**.
4. Back on the store page, paste the key into the "Connect this store" box.
   It's saved in your browser only.

The page then loads the real widget from your backend — the same two lines any
merchant pastes into Shopify or WordPress.

## Then shop your own store

Click a question under **People ask us**, or type your own. Things worth trying:

| Type this | Should surface | Why it's interesting |
|---|---|---|
| `my faucet drips` | Faucet Washer Assortment | The word "washer" never appears in the query |
| `hang a heavy mirror` | Toggle Anchors, Picture Hanging Kit | Describes a job, not a product |
| `the door squeaks` | Silicone Lubricant, Door Hinges | Two different fixes, both right |
| `cold draft from the window` | Weather Seal Tape, Insulation Film | Seasonal intent |
| `my sink is clogged` | Drain Auger | Plain-language symptom |

Then check **Insights** in the dashboard: your searches and product clicks from
this page show up there.

## Files

| File | What it is |
|---|---|
| `index.html` | The storefront. Reads the key from `?key=` or localStorage, injects the widget, renders the stock grid from the CSV. |
| `products.csv` | 18 products — upload this one. |
| `img/*.svg` | Product tiles, generated to match the part numbers. |

Point the page at a different backend with `?api=http://localhost:8000` (useful
when running PolarBear locally).
