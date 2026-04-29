"""
vector_store.py — Qdrant client wrapper for storing and searching CLIP embeddings.

Replaces the local NumPy matmul backend with a remote Qdrant collection.
Everything else in the pipeline (CLIP encoding, filtering, reranking) is unchanged.

Qdrant dashboard: http://16.144.140.219:6333/dashboard
"""

import numpy as np
from qdrant_client import QdrantClient
from qdrant_client.models import (
    Distance,
    FieldCondition,
    Filter,
    MatchValue,
    PointStruct,
    VectorParams,
)

from src.config import (
    COLLECTION_NAME,
    QDRANT_API_KEY,
    QDRANT_COLLECTIONS,
    QDRANT_URL,
    QDRANT_VECTOR_DIM,
    RERANK_CANDIDATE_POOL,
)

# Fields that Qdrant payload filtering supports
FILTERABLE_FIELDS = {
    "gender", "masterCategory", "subCategory", "articleType", "baseColour", "season",
}


def get_client() -> QdrantClient:
    return QdrantClient(url=QDRANT_URL, api_key=QDRANT_API_KEY, timeout=30)


# ── Collection setup ──────────────────────────────────────────────────────────

def ensure_collection(client: QdrantClient, recreate: bool = False) -> None:
    """
    Create the Qdrant collection if it doesn't exist.
    Pass recreate=True to wipe and rebuild (e.g. after changing the CLIP model).
    """
    exists = any(c.name == COLLECTION_NAME for c in client.get_collections().collections)

    if exists and recreate:
        client.delete_collection(COLLECTION_NAME)
        exists = False

    if not exists:
        client.create_collection(
            collection_name=COLLECTION_NAME,
            vectors_config=VectorParams(
                size=QDRANT_VECTOR_DIM,
                distance=Distance.COSINE,   # handles L2 normalisation internally
            ),
        )
        print(f"[INFO] Created Qdrant collection '{COLLECTION_NAME}' "
              f"(dim={QDRANT_VECTOR_DIM}, cosine).")
    else:
        count = client.count(COLLECTION_NAME).count
        print(f"[INFO] Using existing collection '{COLLECTION_NAME}' ({count} points).")


# ── Uploading ─────────────────────────────────────────────────────────────────

def upload_embeddings(
    client: QdrantClient,
    embeddings: np.ndarray,
    catalog: list[dict],
    batch_size: int = 256,
) -> None:
    """
    Upsert all catalog embeddings into Qdrant.

    Args:
        embeddings : float32 array of shape (N, D)
        catalog    : list of N product dicts (payload stored alongside each vector)
        batch_size : number of points per upsert call
    """
    n = len(catalog)
    print(f"[INFO] Uploading {n} embeddings to Qdrant in batches of {batch_size}…")

    for start in range(0, n, batch_size):
        end = min(start + batch_size, n)
        batch_catalog  = catalog[start:end]
        batch_vectors  = embeddings[start:end]

        points = [
            PointStruct(
                id=abs(hash(entry["id"])) % (2**53),   # Qdrant requires uint64-safe int
                vector=batch_vectors[i].tolist(),
                payload={
                    "product_id":      entry["id"],
                    "name":            entry.get("name", ""),
                    "brand":           entry.get("brand", ""),
                    "price":           entry.get("price", 0.0),
                    "url":             entry.get("url", ""),
                    "image_path":      entry.get("image_path", ""),
                    "gender":          entry.get("gender", ""),
                    "masterCategory":  entry.get("masterCategory", ""),
                    "subCategory":     entry.get("subCategory", ""),
                    "articleType":     entry.get("articleType", ""),
                    "baseColour":      entry.get("baseColour", ""),
                    "season":          entry.get("season", ""),
                    "year":            entry.get("year", ""),
                    "usage":           entry.get("usage", ""),
                },
            )
            for i, entry in enumerate(batch_catalog)
        ]

        client.upsert(collection_name=COLLECTION_NAME, points=points)
        print(f"  uploaded {end}/{n}")

    print(f"[INFO] Upload complete. Collection now has "
          f"{client.count(COLLECTION_NAME).count} points.")


# ── Searching ─────────────────────────────────────────────────────────────────

def _build_qdrant_filter(filters: dict | None) -> Filter | None:
    """Convert our simple {field: value} dict into a Qdrant Filter object."""
    if not filters:
        return None

    bad_keys = set(filters) - FILTERABLE_FIELDS
    if bad_keys:
        raise ValueError(
            f"Unknown filter field(s): {bad_keys}. "
            f"Valid fields: {FILTERABLE_FIELDS}"
        )

    conditions = [
        FieldCondition(key=field, match=MatchValue(value=value))
        for field, value in filters.items()
    ]
    return Filter(must=conditions)


def _build_image_url(p: dict) -> str:
    """
    Resolve a payload to a renderable image source. Returns one of:
      - an HTTP(S) URL  (Streamlit's st.image can fetch these directly)
      - a local file path
      - "" if nothing usable was found
    """
    # 1. Explicit URL fields win
    for key in ("image_url", "img_url", "thumbnail_url"):
        v = p.get(key)
        if v and isinstance(v, str) and v.startswith(("http://", "https://")):
            return v

    # 2. Existing image_path may already be a URL
    ip = p.get("image_path", "")
    if ip.startswith(("http://", "https://")):
        return ip

    # 3. Build an S3 HTTPS URL from bucket + key (deepfashion_items pattern)
    bucket = p.get("s3_bucket") or p.get("bucket")
    key    = p.get("s3_key")    or p.get("key") or (ip if ip else None)
    if bucket and key:
        # Region-less virtual-hosted style works for buckets in us-east-1
        # and as a redirect for other regions. Use path-style if region known.
        region = p.get("s3_region")
        host = (f"{bucket}.s3.{region}.amazonaws.com"
                if region else f"{bucket}.s3.amazonaws.com")
        return f"https://{host}/{key.lstrip('/')}"

    # 4. Otherwise assume image_path is a local filesystem path (Myntra dataset)
    return ip


def _normalise_payload(hit, collection_name: str) -> dict:
    """
    Normalise a Qdrant ScoredPoint into our standard result schema.
    Handles different payload shapes across collections gracefully.
    """
    p = hit.payload or {}
    return {
        "score":          round(hit.score, 4),
        "clip_score":     round(hit.score, 4),
        "collection":     collection_name,
        "id":             p.get("product_id", str(hit.id)),
        "name":           p.get("name", p.get("s3_key", "")),   # deepfashion fallback
        "brand":          p.get("brand", ""),
        "price":          p.get("price", 0.0),
        "url":            p.get("url", ""),                     # product URL only
        "image_path":     _build_image_url(p),                   # http(s) OR local path
        "s3_bucket":      p.get("s3_bucket", p.get("bucket", "")),
        "s3_key":         p.get("s3_key",    p.get("key",    "")),
        "gender":         p.get("gender", ""),
        "masterCategory": p.get("masterCategory", ""),
        "subCategory":    p.get("subCategory", ""),
        "articleType":    p.get("articleType", ""),
        "baseColour":     p.get("baseColour", ""),
        "season":         p.get("season", ""),
        "year":           p.get("year", ""),
        "usage":          p.get("usage", ""),
    }


def _search_one_collection(
    client: QdrantClient,
    collection_name: str,
    query_vec: np.ndarray,
    top_n: int,
    qdrant_filter,
) -> list[dict]:
    """Search a single collection, returning [] if it is empty or unreachable."""
    try:
        count = client.count(collection_name, exact=False).count
        if count == 0:
            print(f"[INFO] '{collection_name}' is empty — skipping.")
            return []

        hits = client.query_points(
            collection_name=collection_name,
            query=query_vec.tolist(),
            query_filter=qdrant_filter,
            limit=top_n,
            with_payload=True,
        ).points
        return [_normalise_payload(h, collection_name) for h in hits]
    except Exception as e:
        print(f"[WARN] Could not search '{collection_name}': {e}")
        return []


def search_vectors(
    client: QdrantClient,
    query_vec: np.ndarray,
    top_n: int,
    filters: dict | None = None,
) -> list[dict]:
    """
    Query ALL collections in QDRANT_COLLECTIONS, merge results, and return
    the top-n sorted by descending CLIP score.

    Each result dict includes a 'collection' field so you can see which
    database each item came from.
    """
    qdrant_filter = _build_qdrant_filter(filters)

    if filters:
        print(f"[INFO] Applying filters: {filters}")

    all_results = []
    for col in QDRANT_COLLECTIONS:
        hits = _search_one_collection(client, col, query_vec, top_n, qdrant_filter)
        print(f"[INFO] '{col}': {len(hits)} hits")
        all_results.extend(hits)

    # Merge and re-sort across collections
    all_results.sort(key=lambda x: x["clip_score"], reverse=True)

    # Assign final ranks
    for rank, r in enumerate(all_results[:top_n], start=1):
        r["rank"] = rank

    return all_results[:top_n]
