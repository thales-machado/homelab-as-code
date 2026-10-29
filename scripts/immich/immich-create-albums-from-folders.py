#!/usr/bin/env python3
"""
Homelab - Immich: create albums from the folder structure of an external library
==================================================================================
Each asset is grouped by the name of its immediate parent folder (the deepest
level of the tree, not the top-level category) and added to an album with that name.

Example:
  Bike/Bike 04_2023/photo.jpg       -> album "Bike 04_2023"
  Screenshots/photo.png             -> album "Screenshots" (no subfolder)

Usage:
  pip install requests
  export IMMICH_API_KEY='your-api-key'
  python3 immich-create-albums-from-folders.py [--dry-run] [--library-name "Lib Externa - Thales"]

  # Renamed albums in the UI? Normalize the album name to the
  # "<Description> - MM-YYYY" pattern and sync the folder name on disk:
  python3 immich-create-albums-from-folders.py --rename-folders [--dry-run]

Points to https://immich.lan.example.com by default (override via IMMICH_URL). The certificate
is public (Let's Encrypt via Traefik) - validated natively, no custom CA.
"""

import argparse
import os
import re
from collections import defaultdict
from pathlib import PurePosixPath

import requests

HOMELAB_ENV = "/opt/homelab/hosts/urahara/.env"
IMMICH_URL = "https://immich.lan.example.com"
DEFAULT_LIBRARY_NAME = "Lib Externa - Thales"
CONTAINER_LIBRARY_PREFIX = "/mnt/library"
HOST_LIBRARY_PREFIX = "/mnt/immich-external"


def load_api_key():
    key = os.getenv("IMMICH_API_KEY")
    if key:
        return key
    if os.path.isfile(HOMELAB_ENV):
        with open(HOMELAB_ENV) as f:
            for line in f:
                if line.startswith("IMMICH_API_KEY="):
                    return line.strip().split("=", 1)[1]
    print(f"❌ IMMICH_API_KEY is not set (env or {HOMELAB_ENV})")
    raise SystemExit(1)


def build_session():
    return requests.Session()


def fetch_library_id(session, base_url, library_name):
    resp = session.get(f"{base_url}/api/libraries")
    resp.raise_for_status()
    for lib in resp.json():
        if lib.get("name") == library_name:
            return lib["id"]
    print(f"❌ Library '{library_name}' not found.")
    print(f"   Available: {[lib.get('name') for lib in resp.json()]}")
    raise SystemExit(1)


def search_assets(session, base_url, extra_filter):
    assets = []
    page = 1
    while True:
        payload = {"page": page, "size": 1000}
        payload.update(extra_filter)
        resp = session.post(f"{base_url}/api/search/metadata", json=payload)
        resp.raise_for_status()
        body = resp.json().get("assets", resp.json())
        items = body.get("items", [])
        assets.extend(items)
        if not items or not body.get("nextPage"):
            break
        page += 1
    return assets


def fetch_all_assets(session, base_url, library_id):
    return search_assets(session, base_url, {"libraryId": library_id})


def group_by_leaf_folder(assets):
    groups = defaultdict(list)
    for asset in assets:
        original_path = asset.get("originalPath")
        asset_id = asset.get("id")
        if not original_path or not asset_id:
            continue
        album_name = PurePosixPath(original_path).parent.name
        groups[album_name].append(asset_id)
    return groups


def fetch_existing_albums(session, base_url):
    resp = session.get(f"{base_url}/api/albums")
    resp.raise_for_status()
    return {album["albumName"]: album["id"] for album in resp.json()}


def sync_albums(session, base_url, groups, existing_albums, dry_run):
    created, updated = 0, 0
    for album_name, asset_ids in sorted(groups.items()):
        album_id = existing_albums.get(album_name)

        if dry_run:
            action = "update" if album_id else "create"
            print(f"  🔍 [dry-run] {action} album '{album_name}' with {len(asset_ids)} asset(s)")
            continue

        if album_id:
            resp = session.put(
                f"{base_url}/api/albums/{album_id}/assets",
                json={"ids": asset_ids},
            )
            resp.raise_for_status()
            added = sum(1 for r in resp.json() if r.get("success"))
            print(f"  ✅ Album '{album_name}' updated: +{added} new asset(s)")
            updated += 1
        else:
            resp = session.post(
                f"{base_url}/api/albums",
                json={"albumName": album_name, "assetIds": asset_ids},
            )
            resp.raise_for_status()
            print(f"  ✅ Album '{album_name}' created with {len(asset_ids)} asset(s)")
            created += 1

    return created, updated


def fetch_albums(session, base_url):
    resp = session.get(f"{base_url}/api/albums")
    resp.raise_for_status()
    return resp.json()


# Matches "<description> <sep> <month|year> <sep> <year|month>" with any mix
# of space/hyphen/underscore/slash as separator.
DATE_SUFFIX_RE = re.compile(r"^(?P<desc>.+?)[\s\-_/]+(?P<d1>\d{1,4})[\s\-_/]+(?P<d2>\d{1,4})$")


def normalize_album_name(name):
    """Reformat to '<Description> - MM-YYYY'. Without a recognizable trailing date, keep it as is."""
    name = name.strip()
    match = DATE_SUFFIX_RE.match(name)
    if not match:
        return name

    d1, d2 = match.group("d1"), match.group("d2")
    year = d1 if len(d1) == 4 else d2 if len(d2) == 4 else None
    month = d2 if year == d1 else d1
    if year is None or len(month) > 2 or not (1 <= int(month) <= 12):
        return name

    desc = match.group("desc").strip(" -_")
    return f"{desc} - {month.zfill(2)}-{year}"


def rename_album(session, base_url, album_id, new_name):
    resp = session.patch(f"{base_url}/api/albums/{album_id}", json={"albumName": new_name})
    resp.raise_for_status()


def leaf_folder_container_path(assets):
    parents = {
        str(PurePosixPath(a["originalPath"]).parent)
        for a in assets
        if a.get("originalPath", "").startswith(CONTAINER_LIBRARY_PREFIX)
    }
    if len(parents) != 1:
        return None
    return parents.pop()


def container_path_to_host(container_path):
    return HOST_LIBRARY_PREFIX + container_path[len(CONTAINER_LIBRARY_PREFIX):]


def trigger_library_scan(session, base_url, library_id):
    resp = session.post(f"{base_url}/api/libraries/{library_id}/scan")
    resp.raise_for_status()


def rename_folders_from_albums(session, base_url, library_id, dry_run):
    albums = fetch_albums(session, base_url)
    print(f"   {len(albums)} album(s) found in Immich")
    albums_renamed = 0
    folders_renamed = 0

    for album in albums:
        original_album_name = album["albumName"]
        album_name = normalize_album_name(original_album_name)
        assets = search_assets(session, base_url, {"albumIds": [album["id"]]})
        print(f"  • '{original_album_name}': {len(assets)} asset(s)")

        if album_name != original_album_name:
            if dry_run:
                print(f"    🔍 [dry-run] rename album '{original_album_name}' -> '{album_name}'")
            else:
                rename_album(session, base_url, album["id"], album_name)
                print(f"    ✅ Album renamed: '{original_album_name}' -> '{album_name}'")
                albums_renamed += 1

        if not assets:
            continue

        if "/" in album_name or "\\" in album_name:
            print(f"    ⚠️  album name contains '/' or '\\' — not a valid folder name, skipping")
            continue

        container_path = leaf_folder_container_path(assets)
        if container_path is None:
            print(f"    ⚠️  assets spread across more than one folder (or outside the library) — skipping")
            continue

        host_path = container_path_to_host(container_path)
        current_name = os.path.basename(host_path)
        print(f"    current folder on disk: '{current_name}' ({host_path})")
        if current_name == album_name:
            print("    already in sync")
            continue

        new_host_path = os.path.join(os.path.dirname(host_path), album_name)
        case_only_change = current_name.lower() == album_name.lower()

        if os.path.exists(new_host_path) and not case_only_change:
            print(f"  ❌ A folder '{album_name}' already exists — skipping rename of '{current_name}'")
            continue

        if dry_run:
            print(f"  🔍 [dry-run] rename folder '{current_name}' -> '{album_name}'")
            continue

        if case_only_change:
            # case-insensitive filesystem (network/NAS): an intermediate name is
            # needed to force the case change
            tmp_path = host_path + ".rename-tmp"
            os.rename(host_path, tmp_path)
            os.rename(tmp_path, new_host_path)
        else:
            os.rename(host_path, new_host_path)

        print(f"  ✅ Folder renamed: '{current_name}' -> '{album_name}'")
        folders_renamed += 1

    if folders_renamed and not dry_run:
        print("\n🔄 Triggering a new library scan (asset paths stay stale until the scan runs)...")
        trigger_library_scan(session, base_url, library_id)

    return albums_renamed, folders_renamed


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dry-run", action="store_true", help="Show the changes without applying them")
    parser.add_argument("--library-name", default=DEFAULT_LIBRARY_NAME, help="Name of the external library in Immich")
    parser.add_argument("--rename-folders", action="store_true",
                         help="Instead of creating albums from folders, rename the folders on disk to match the current album names")
    args = parser.parse_args()

    api_key = load_api_key()
    base_url = os.getenv("IMMICH_URL", IMMICH_URL).rstrip("/")
    print(f"🔗 Immich at {base_url}")

    session = build_session()
    session.headers.update({"x-api-key": api_key, "Content-Type": "application/json"})

    print(f"📁 Looking up library '{args.library_name}'...")
    library_id = fetch_library_id(session, base_url, args.library_name)

    if args.rename_folders:
        print(f"\n{'🔍 Simulation (--dry-run):' if args.dry_run else '🚀 Normalizing albums and folders...'}")
        albums_renamed, folders_renamed = rename_folders_from_albums(session, base_url, library_id, args.dry_run)
        if not args.dry_run:
            print(f"\n🎉 Done! {albums_renamed} album(s) renamed, {folders_renamed} folder(s) renamed.")
        return

    print("📦 Listing library assets...")
    assets = fetch_all_assets(session, base_url, library_id)
    print(f"   {len(assets)} asset(s) found")

    groups = group_by_leaf_folder(assets)
    print(f"\n🗂️  {len(groups)} album(s) identified from the folder structure:")
    for name, ids in sorted(groups.items()):
        print(f"   - {name}: {len(ids)} asset(s)")

    existing_albums = fetch_existing_albums(session, base_url)

    print(f"\n{'🔍 Simulation (--dry-run):' if args.dry_run else '🚀 Syncing albums...'}")
    created, updated = sync_albums(session, base_url, groups, existing_albums, args.dry_run)

    if not args.dry_run:
        print(f"\n🎉 Done! {created} album(s) created, {updated} updated.")


if __name__ == "__main__":
    main()
