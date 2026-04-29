"""
app.py — Streamlit frontend for Fashion Image Similarity Search.

Run with:
    streamlit run app.py

Requires:  pip install streamlit
"""

import io

import streamlit as st
from PIL import Image

from src.data_loader import load_catalog
from src.search import FashionSearchEngine

# ── Page config ───────────────────────────────────────────────────────────────

st.set_page_config(
    page_title="Fashion Finder",
    page_icon="👗",
    layout="wide",
)

st.title("Fashion Image Similarity Search")
st.caption("Upload a clothing photo — or describe what you want — and find similar products.")

# ── Load engine and catalog metadata once ────────────────────────────────────

@st.cache_resource(show_spinner="Loading CLIP model and product index…")
def get_engine() -> FashionSearchEngine:
    engine = FashionSearchEngine()
    engine.build_index()
    return engine


@st.cache_data(show_spinner=False)
def get_filter_options() -> dict:
    """Pull unique values for each filterable field from the catalog."""
    catalog = load_catalog()
    options = {}
    for field in ("gender", "masterCategory", "subCategory", "articleType", "baseColour", "season"):
        vals = sorted({e.get(field, "") for e in catalog if e.get(field)})
        options[field] = ["(any)"] + vals
    return options


engine = get_engine()
filter_options = get_filter_options()

# ── Sidebar ───────────────────────────────────────────────────────────────────

with st.sidebar:
    st.header("Search settings")
    top_k       = st.slider("Number of results", 1, 20, 5)
    search_mode = st.radio("Search mode", ["Image upload", "Text description"])

    st.divider()
    st.subheader("Filters")
    st.caption("Narrow results by metadata before CLIP retrieval.")

    sel_gender   = st.selectbox("Gender",         filter_options["gender"])
    sel_cat      = st.selectbox("Category",       filter_options["masterCategory"])
    sel_subcat   = st.selectbox("Subcategory",    filter_options["subCategory"])
    sel_type     = st.selectbox("Article type",   filter_options["articleType"])
    sel_colour   = st.selectbox("Base colour",    filter_options["baseColour"])
    sel_season   = st.selectbox("Season",         filter_options["season"])

    st.divider()
    st.subheader("Reranking")
    st.caption("Blends CLIP score with keyword match.")
    rerank_on    = st.toggle("Enable reranking", value=True)
    rerank_hint  = st.text_input(
        "Rerank text hint (image mode only)",
        placeholder="e.g. navy blue check shirt",
    )

# ── Build filter dict from sidebar selections ─────────────────────────────────

def build_filters() -> dict | None:
    f = {}
    if sel_gender  != "(any)": f["gender"]          = sel_gender
    if sel_cat     != "(any)": f["masterCategory"]   = sel_cat
    if sel_subcat  != "(any)": f["subCategory"]      = sel_subcat
    if sel_type    != "(any)": f["articleType"]      = sel_type
    if sel_colour  != "(any)": f["baseColour"]       = sel_colour
    if sel_season  != "(any)": f["season"]           = sel_season
    return f or None

# ── Main search area ──────────────────────────────────────────────────────────

results = []

if search_mode == "Image upload":
    uploaded = st.file_uploader(
        "Upload a clothing image", type=["jpg", "jpeg", "png", "webp"]
    )
    if uploaded:
        query_image = Image.open(io.BytesIO(uploaded.read())).convert("RGB")
        st.image(query_image, caption="Query image", width=240)

        if st.button("Search", type="primary"):
            with st.spinner("Finding similar items…"):
                try:
                    results = engine.search(
                        query_image,
                        top_k=top_k,
                        filters=build_filters(),
                        rerank_query=rerank_hint.strip() or None,
                    )
                except ValueError as e:
                    st.error(str(e))

else:  # Text description
    text_query = st.text_input("Describe the item you're looking for",
                               placeholder="e.g. red floral summer dress")
    if text_query and st.button("Search", type="primary"):
        with st.spinner("Finding similar items…"):
            try:
                results = engine.search_by_text(
                    text_query,
                    top_k=top_k,
                    filters=build_filters(),
                    rerank=rerank_on,
                )
            except ValueError as e:
                st.error(str(e))

# ── Display results ───────────────────────────────────────────────────────────

if results:
    st.subheader(f"Top {len(results)} Results")
    cols = st.columns(min(len(results), 5))

    for i, r in enumerate(results):
        col = cols[i % 5]
        with col:
            img_src = r.get("image_path", "")
            try:
                if img_src.startswith(("http://", "https://")):
                    # Let Streamlit fetch URLs directly (S3, CDNs, etc.)
                    col.image(img_src, use_container_width=True)
                elif img_src:
                    col.image(Image.open(img_src), use_container_width=True)
                else:
                    col.write("_(no image source)_")
            except Exception as e:
                col.write(f"_(image unavailable)_")
                col.caption(f"src: {img_src[:60]}")
                col.caption(f"err: {str(e)[:80]}")

            col.markdown(f"**{r['name']}**")

            # Metadata tags — only show non-empty fields
            tags = " · ".join(filter(None, [
                r.get("articleType", ""),
                r.get("baseColour", ""),
                r.get("gender", ""),
            ]))
            if tags:
                col.caption(tags)

            # Score — show clip + keyword breakdown if reranked
            if "keyword_score" in r:
                col.markdown(
                    f"Score `{r['score']:.3f}`  "
                    f"*(clip `{r['clip_score']:.3f}` · kw `{r['keyword_score']:.3f}`)*"
                )
            else:
                col.markdown(f"Score `{r['score']:.3f}`")

            # Price — only show if non-zero
            if r.get("price"):
                col.markdown(f"${r['price']:.2f}")

            # Source collection badge
            col.caption(f"source: {r.get('collection', 'fashion')}")

            if r.get("url"):
                col.markdown(f"[View product]({r['url']})")
