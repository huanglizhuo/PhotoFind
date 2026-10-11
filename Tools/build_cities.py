#!/usr/bin/env python3
"""Builds SemanticPhotos/Resources/cities.sqlite, the offline city database
behind place names (PRD F3.5.1 / F4.8).

Source: GeoNames (https://www.geonames.org), CC BY 4.0 — credited in the app's
About page. Uses cities with population > 15,000 (~34k rows, ~2 MB) plus
Chinese names picked by language tag from the alternate-names dump.

Usage: python3 Tools/build_cities.py <download-cache-dir> [output.sqlite]
Downloads (~210 MB, cached) cities15000.zip, admin1CodesASCII.txt and
alternateNamesV2.zip. Standard library only; rerun whenever the data should
be refreshed.
"""
import io
import os
import sqlite3
import subprocess
import sys
import urllib.error
import urllib.request
import zipfile

BASE = "https://download.geonames.org/export/dump/"
# Higher wins: simplified Chinese first, then generic, then traditional.
ZH_RANK = {"zh-CN": 5, "zh-Hans": 5, "zh": 4, "zh-SG": 3, "zh-TW": 2, "zh-HK": 2, "zh-Hant": 1}


def fetch(cache, name):
    path = os.path.join(cache, name)
    if not os.path.exists(path):
        print(f"downloading {name} …", file=sys.stderr)
        try:
            urllib.request.urlretrieve(BASE + name, path + ".part")
        except urllib.error.URLError:
            # python.org builds ship without CA certificates; the system curl has them.
            subprocess.run(["curl", "-fsSL", "-o", path + ".part", BASE + name], check=True)
        os.replace(path + ".part", path)
    return path


def lines(zip_path, member):
    with zipfile.ZipFile(zip_path) as z, z.open(member) as f:
        yield from io.TextIOWrapper(f, encoding="utf-8")


def main():
    cache = sys.argv[1]
    here = os.path.dirname(os.path.abspath(__file__))
    out = sys.argv[2] if len(sys.argv) > 2 else os.path.join(here, "..", "SemanticPhotos", "Resources", "cities.sqlite")
    os.makedirs(cache, exist_ok=True)

    cities = []
    for line in lines(fetch(cache, "cities15000.zip"), "cities15000.txt"):
        c = line.rstrip("\n").split("\t")
        # id, name, lat, lon, country, admin1 code, population
        cities.append((int(c[0]), c[1], float(c[4]), float(c[5]), c[8], f"{c[8]}.{c[10]}", int(c[14] or 0)))

    admin1 = {}
    with open(fetch(cache, "admin1CodesASCII.txt"), encoding="utf-8") as f:
        for line in f:
            code, name, _ascii, gid = line.rstrip("\n").split("\t")
            admin1[code] = (int(gid), name)

    wanted = {c[0] for c in cities} | {gid for gid, _ in admin1.values()}
    best = {}  # geonameid -> (rank, name)
    for line in lines(fetch(cache, "alternateNamesV2.zip"), "alternateNamesV2.txt"):
        f = line.rstrip("\n").split("\t")
        gid, lang = int(f[1]), f[2]
        if gid not in wanted or lang not in ZH_RANK or f[7] == "1":  # f[7]: historic
            continue
        rank = ZH_RANK[lang] + (0.5 if f[4] == "1" else 0) + (0.2 if f[5] == "1" else 0)  # preferred, short
        if rank > best.get(gid, (-1, ""))[0]:
            best[gid] = (rank, f[3])

    if os.path.exists(out):
        os.remove(out)
    db = sqlite3.connect(out)
    db.executescript("""
        CREATE TABLE admin1(code TEXT PRIMARY KEY, name TEXT NOT NULL, name_zh TEXT) WITHOUT ROWID;
        CREATE TABLE city(id INTEGER PRIMARY KEY, name TEXT NOT NULL, name_zh TEXT,
                          lat REAL NOT NULL, lon REAL NOT NULL, country TEXT NOT NULL, admin1 TEXT,
                          population INTEGER NOT NULL);
    """)
    db.executemany("INSERT INTO admin1 VALUES(?,?,?)",
                   [(code, name, best.get(gid, (0, None))[1]) for code, (gid, name) in admin1.items()])
    db.executemany("INSERT INTO city VALUES(?,?,?,?,?,?,?,?)",
                   [(i, n, best.get(i, (0, None))[1], round(la, 4), round(lo, 4), cc, a1, pop)
                    for i, n, la, lo, cc, a1, pop in cities])
    db.execute("CREATE INDEX city_lat ON city(lat)")
    db.commit()
    db.execute("VACUUM")
    db.close()
    zh = sum(1 for c in cities if c[0] in best)
    print(f"{out}: {len(cities)} cities ({zh * 100 // len(cities)}% with Chinese names), "
          f"{os.path.getsize(out) / 1e6:.1f} MB", file=sys.stderr)


if __name__ == "__main__":
    main()
