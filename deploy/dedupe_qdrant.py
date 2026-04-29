"""
dedupe_qdrant.py - remove duplicate s3_key entries from a Qdrant collection.

Scrolls the entire collection, groups points by their s3_key payload field,
keeps the first ID in each group, and deletes the rest.

Usage:
    python deploy/dedupe_qdrant.py                # dry run (default)
    python deploy/dedupe_qdrant.py --apply        # actually delete

Requirements:
    pip install qdrant-client
"""

import argparse
from collections import defaultdict

from qdrant_client import QdrantClient

# Match src/config.py defaults
QDRANT_URL      = "http://16.144.140.219:6333"
QDRANT_API_KEY  = None
COLLECTION_NAME = "deepfashion_items"
DEDUPE_FIELD    = "s3_key"      # change to "image_path" or other if needed
SCROLL_BATCH    = 1000
DELETE_BATCH    = 1000


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url",        default=QDRANT_URL)
    parser.add_argument("--collection", default=COLLECTION_NAME)
    parser.add_argument("--field",      default=DEDUPE_FIELD)
    parser.add_argument("--apply", action="store_true",
                        help="Actually delete duplicates (default: dry run)")
    args = parser.parse_args()

    client = QdrantClient(url=args.url, api_key=QDRANT_API_KEY, timeout=60)

    total_before = client.count(args.collection).count
    print(f"[INFO] Collection '{args.collection}' has {total_before} points")

    # ── 1. Scroll all points, grouping by dedupe field ───────────────────────
    groups: dict[str, list] = defaultdict(list)
    null_count = 0
    scanned = 0
    offset = None

    while True:
        points, offset = client.scroll(
            collection_name=args.collection,
            limit=SCROLL_BATCH,
            offset=offset,
            with_payload=[args.field],
            with_vectors=False,
        )
        for p in points:
            key = (p.payload or {}).get(args.field)
            if key is None or key == "":
                null_count += 1
                continue
            groups[key].append(p.id)
        scanned += len(points)
        print(f"  scanned {scanned}/{total_before}...")
        if offset is None:
            break

    print(f"[INFO] Scanned {scanned} points")
    print(f"[INFO] Found {len(groups)} unique values for '{args.field}'")
    if null_count:
        print(f"[WARN] {null_count} points had null/missing '{args.field}' "
              f"(skipped — won't be touched)")

    # ── 2. Build delete list ─────────────────────────────────────────────────
    to_delete: list = []
    dup_groups = 0
    for key, ids in groups.items():
        if len(ids) > 1:
            # Keep the first (smallest by Python ordering); delete the rest
            ids_sorted = sorted(ids, key=str)
            to_delete.extend(ids_sorted[1:])
            dup_groups += 1

    print(f"[INFO] {dup_groups} groups have duplicates")
    print(f"[INFO] {len(to_delete)} duplicate points to delete")

    if not to_delete:
        print("[OK] No duplicates found. Nothing to do.")
        return

    if not args.apply:
        # Show a sample so user can sanity check before re-running with --apply
        print()
        print("Sample of groups with duplicates (showing up to 5):")
        shown = 0
        for key, ids in groups.items():
            if len(ids) > 1:
                print(f"  {args.field}={key!r}  -> {len(ids)} points: {ids[:5]}"
                      f"{'...' if len(ids) > 5 else ''}")
                shown += 1
                if shown >= 5:
                    break
        print()
        print("Dry run only. Re-run with --apply to delete the duplicates above.")
        return

    # ── 3. Delete in batches ─────────────────────────────────────────────────
    print(f"[INFO] Deleting {len(to_delete)} points in batches of {DELETE_BATCH}...")
    for i in range(0, len(to_delete), DELETE_BATCH):
        batch = to_delete[i:i + DELETE_BATCH]
        client.delete(collection_name=args.collection, points_selector=batch)
        print(f"  deleted {min(i + DELETE_BATCH, len(to_delete))}/{len(to_delete)}")

    total_after = client.count(args.collection).count
    print(f"[OK] Done. Collection now has {total_after} points "
          f"(was {total_before}, removed {total_before - total_after}).")


if __name__ == "__main__":
    main()
