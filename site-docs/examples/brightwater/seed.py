#!/usr/bin/env python3
"""Seed the Brightwater Rentals example into a running Facet dev instance.

Prerequisites: the three domains (equipment, clients, rentals) exist, the
Brightwater roles exist, and the four people (Nadia, Tom, Lucía, Ravi) hold
accounts. `load.sh` sets all of that up.

Data is deterministic: fixed names, fixed prices, and every date derived from
the fixed anchor date 2026-12-07 (a Monday), documented in the README. A
re-seed produces the same corpus, so screenshots stay stable.

Usage: python3 seed.py [base_url]   (default http://127.0.0.1:3000)
"""
import json
import sys
import urllib.parse
import urllib.request
import http.cookiejar

BASE = sys.argv[1] if len(sys.argv) > 1 else "http://127.0.0.1:3000"
ADMIN_EMAIL = "admin@example.tld"
ADMIN_PASSWORD = "admin"

# Fixed anchor: the Monday the example's bookings radiate from.
ANCHOR = "2026-12-07"

jar = http.cookiejar.CookieJar()
opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))


def call(method, path, body=None):
    """One API call. Returns (status, parsed_body)."""
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(BASE + path, data=data, method=method)
    req.add_header("Content-Type", "application/json")
    req.add_header("X-Requested-With", "XMLHttpRequest")
    try:
        with opener.open(req) as res:
            return res.status, json.loads(res.read() or b"{}")
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read() or b"{}")


def created(path, body):
    """POST; returns the new document's id, or raises with the error text."""
    status, res = call("POST", path, body)
    if status != 201:
        raise RuntimeError(f"POST {path} -> {status}: {json.dumps(res)[:300]}")
    return res["meta"]["id"]


def find(path, field, value):
    """GET a list filtered by one field; returns the first hit's id or None."""
    sep = "&" if "?" in path else "?"
    status, res = call("GET", f"{path}{sep}filters[{field}__eq]={urllib.parse.quote(str(value))}")
    if status != 200:
        return None
    items = res.get("data") or []
    return items[0]["meta"]["id"] if items else None


def ensure(path, field, value, body):
    """Idempotent create: reuse the row the field already names, else create."""
    existing = find(path, field, value)
    if existing:
        return existing
    return created(path, body)


# ── login ────────────────────────────────────────────────────────────────
status, res = call("POST", "/Api/iam/login", {"email": ADMIN_EMAIL, "password": ADMIN_PASSWORD})
if status != 200:
    raise SystemExit(f"admin login failed: {status} {json.dumps(res)[:200]}")
print("admin session ok")

# ── equipment: categories then items ─────────────────────────────────────
CATEGORIES = ["Tents", "Staging", "Sound", "Lighting", "Power", "Furniture"]
cat_ids = {}
for name in CATEGORIES:
    cat_ids[name] = ensure("/Api/equipment/Category", "name", name, {"name": name})
print(f"categories: {len(cat_ids)}")

# (name, category, serial, purchase EUR) — 40 items across 6 categories.
ITEMS = [
    # Tents (7)
    ("Main tent 10x15", "Tents", "TN-10015-A", 4800.00),
    ("Main tent 10x15", "Tents", "TN-10015-B", 4800.00),
    ("Pagoda tent 5x5", "Tents", "TN-0505-A", 1500.00),
    ("Pagoda tent 5x5", "Tents", "TN-0505-B", 1500.00),
    ("Stretch tent 8x12", "Tents", "TN-0812-A", 2600.00),
    ("Marquee 20x30", "Tents", "TN-2030-A", 12000.00),
    ("Festival tent 15x20", "Tents", "TN-1520-A", 7400.00),
    # Staging (6)
    ("Stage deck 2x1", "Staging", "ST-0201-A", 420.00),
    ("Stage deck 2x1", "Staging", "ST-0201-B", 420.00),
    ("Stage deck 2x1", "Staging", "ST-0201-C", 420.00),
    ("Stage deck 2x1", "Staging", "ST-0201-D", 420.00),
    ("Stage riser 1x1", "Staging", "SR-0101-A", 260.00),
    ("Crowd barrier 2m", "Staging", "CB-02-A", 95.00),
    # Sound (7)
    ("Line array speaker", "Sound", "LA-SPK-A", 3200.00),
    ("Line array speaker", "Sound", "LA-SPK-B", 3200.00),
    ("Subwoofer 18in", "Sound", "SUB-18-A", 1800.00),
    ("Subwoofer 18in", "Sound", "SUB-18-B", 1800.00),
    ("Digital mixer 32ch", "Sound", "MIX-32-A", 5400.00),
    ("Wireless mic set", "Sound", "WM-SET-A", 640.00),
    ("Wireless mic set", "Sound", "WM-SET-B", 640.00),
    # Lighting (7)
    ("LED par 7x12W", "Lighting", "LP-712-A", 180.00),
    ("LED par 7x12W", "Lighting", "LP-712-B", 180.00),
    ("LED par 7x12W", "Lighting", "LP-712-C", 180.00),
    ("LED par 7x12W", "Lighting", "LP-712-D", 180.00),
    ("Moving head beam", "Lighting", "MH-BM-A", 980.00),
    ("Moving head beam", "Lighting", "MH-BM-B", 980.00),
    ("Fairy light curtain", "Lighting", "FL-CUR-A", 240.00),
    # Power (6)
    ("Generator 20kVA", "Power", "GEN-20-A", 6900.00),
    ("Generator 20kVA", "Power", "GEN-20-B", 6900.00),
    ("Distro box 63A", "Power", "DB-63-A", 310.00),
    ("Distro box 63A", "Power", "DB-63-B", 310.00),
    ("Cable ramp 5m", "Power", "CR-05-A", 150.00),
    ("UPS 3kVA", "Power", "UPS-3-A", 720.00),
    # Furniture (7)
    ("Folding chair white", "Furniture", "FC-WHT-A", 22.00),
    ("Folding chair white", "Furniture", "FC-WHT-B", 22.00),
    ("Folding chair white", "Furniture", "FC-WHT-C", 22.00),
    ("Round table 180cm", "Furniture", "RT-180-A", 140.00),
    ("Round table 180cm", "Furniture", "RT-180-B", 140.00),
    ("Bistro light set 20m", "Furniture", "BL-20-A", 110.00),
    ("Dance floor panel 1x1", "Furniture", "DF-11-A", 95.00),
]

item_ids = {}
for name, cat, serial, price in ITEMS:
    item_ids[serial] = ensure("/Api/equipment/Item", "serial_number", serial, {
        "name": name,
        "category": f"equipment.Category.{cat_ids[cat]}",
        "status": "available",
        "purchase_price": {"value": f"{price:.2f}", "currency": "EUR"},
        "serial_number": serial,
    })
print(f"items: {len(item_ids)}")

# ── clients: companies then contacts (children) ──────────────────────────
def account_id(email):
    """Resolve an account by email — ids differ per instance, never hardcode."""
    aid = find("/Api/iam/Account", "email", email)
    if not aid:
        raise SystemExit(f"account not found: {email} (run load.sh first)")
    return aid

nadia_id = account_id("nadia@brightwater.example")
tom_id = account_id("tom@brightwater.example")
lucia_id = account_id("lucia@brightwater.example")
ravi_id = account_id("ravi@brightwater.example")

COMPANIES = [
    # (name, city, account_manager)
    ("Maison Lumière", "Lyon", tom_id),
    ("Festival des Collines", "Annecy", tom_id),
    ("Harbour Events Ltd", "Marseille", nadia_id),
    ("Cabinet Moreau", "Grenoble", tom_id),
    ("Vineyard Wedges", "Beaune", nadia_id),
    ("TechCamp Europe", "Lille", nadia_id),
    ("Château de Vireloup", "Dijon", tom_id),
    ("Sporting Club du Parc", "Lyon", nadia_id),
    ("Mairie de Saint-Clair", "Saint-Clair", tom_id),
    ("Atelier Sonore", "Nice", nadia_id),
]
# (company index, full name, email, role at company)
CONTACTS = [
    (0, "Claire Fontaine", "claire@maison-lumiere.example", "Events lead"),
    (0, "Marc Dubois", "marc@maison-lumiere.example", "Operations"),
    (1, "Sofia Marino", "sofia@festival-collines.example", "Programme director"),
    (1, "Jules Perrin", "jules@festival-collines.example", "Site manager"),
    (2, "Hélène Girard", "helene@harbour-events.example", "Producer"),
    (3, "Antoine Moreau", "antoine@cabinet-moreau.example", "Partner"),
    (4, "Isabelle Roche", "isabelle@vineyard-wedges.example", "Owner"),
    (4, "Paul Roche", "paul@vineyard-wedges.example", "Co-owner"),
    (5, "Dana Kovacs", "dana@techcamp-europe.example", "Community lead"),
    (5, "Leo Brandt", "leo@techcamp-europe.example", "Logistics"),
    (6, "Margot Lefèvre", "margot@chateau-vireloup.example", "Estate manager"),
    (7, "Karim Benali", "karim@sporting-parc.example", "Facilities"),
    (8, "Yvette Blanc", "yvette@saint-clair.example", "Deputy mayor"),
    (9, "Théo Marchetti", "theo@atelier-sonore.example", "Sound engineer"),
]

company_ids = []
for name, city, manager in COMPANIES:
    company_ids.append(ensure("/Api/clients/Company", "name", name, {
        "name": name, "city": city, "account_manager": f"iam.Account.{manager}",
    }))

contact_count = 0
for co_idx, full_name, email, role in CONTACTS:
    ensure(f"/Api/clients/Company/{company_ids[co_idx]}/contacts", "full_name", full_name, {
        "full_name": full_name, "email": email, "role": role,
    })
    contact_count += 1
print(f"companies: {len(company_ids)}, contacts: {contact_count}")

# ── rentals: bookings + lines ────────────────────────────────────────────
# (company idx, start, end, state, notes, lines=[(serial, qty, price)])
BOOKINGS = [
    (0, "2026-12-11", "2026-12-13", "confirmed", "Wedding — main lawn. Site contact: Claire.",
     [("TN-10015-A", 1, 620.00), ("LP-712-A", 8, 90.00), ("BL-20-A", 2, 45.00),
      ("FC-WHT-A", 60, 3.50), ("RT-180-A", 6, 55.00)]),
    (1, "2026-12-18", "2026-12-21", "draft", "Festival warm-up weekend. Awaiting signed quote.",
     [("ST-0201-A", 6, 85.00), ("LA-SPK-A", 2, 340.00), ("SUB-18-A", 1, 210.00),
      ("MIX-32-A", 1, 260.00)]),
    (2, "2026-12-19", "2026-12-20", "confirmed", "Corporate party — harbour hall.",
     [("MH-BM-A", 4, 120.00), ("LP-712-B", 6, 90.00), ("WM-SET-A", 2, 70.00)]),
    (3, "2027-01-08", "2027-01-09", "draft", "Seminar room, 80 people.",
     [("FC-WHT-B", 80, 3.50), ("RT-180-B", 10, 55.00)]),
    (4, "2026-12-12", "2026-12-14", "confirmed", "Vineyard wedding — stretch tent.",
     [("TN-0812-A", 1, 380.00), ("BL-20-A", 1, 45.00), ("FC-WHT-C", 50, 3.50)]),
    (5, "2027-01-15", "2027-01-17", "draft", "Tech camp — main stage.",
     [("ST-0201-B", 8, 85.00), ("LA-SPK-B", 2, 340.00), ("SUB-18-B", 2, 210.00),
      ("GEN-20-A", 1, 480.00), ("DB-63-A", 2, 40.00), ("CR-05-A", 4, 25.00)]),
    (6, "2026-12-27", "2026-12-29", "confirmed", "Castle New Year dinner.",
     [("TN-0505-A", 2, 190.00), ("DF-11-A", 24, 18.00), ("LP-712-C", 10, 90.00)]),
    (7, "2027-01-22", "2027-01-24", "returned", "Club tournament — done, items back.",
     [("TN-0505-B", 1, 190.00), ("CB-02-A", 10, 18.00)]),
    (8, "2027-01-29", "2027-01-30", "confirmed", "Town hall winter market.",
     [("TN-2030-A", 1, 980.00), ("UPS-3-A", 1, 90.00), ("BL-20-A", 1, 45.00)]),
    (9, "2027-02-05", "2027-02-06", "draft", "Studio session — sound only.",
     [("WM-SET-B", 2, 70.00), ("MIX-32-A", 1, 260.00)]),
    (0, "2027-01-09", "2027-01-10", "confirmed", "Second wedding for Maison Lumière.",
     [("TN-10015-B", 1, 620.00), ("LP-712-D", 6, 90.00), ("FC-WHT-A", 40, 3.50)]),
    (2, "2027-02-12", "2027-02-14", "draft", "Harbour spring fair — hold the date.",
     [("TN-1520-A", 1, 640.00), ("GEN-20-B", 1, 480.00)]),
    (4, "2027-02-19", "2027-02-21", "draft", "Vineyard pruning festival.",
     [("TN-0812-A", 1, 380.00), ("BL-20-A", 3, 45.00)]),
    (6, "2026-12-05", "2026-12-06", "returned", "Charity gala — done.",
     [("LP-712-B", 4, 90.00), ("DF-11-A", 12, 18.00)]),
    (1, "2026-11-28", "2026-11-29", "returned", "Press launch — done.",
     [("ST-0201-C", 4, 85.00), ("WM-SET-A", 1, 70.00)]),
]

def find_booking(client_ref, start):
    """Idempotency for bookings: they carry no unique field, so match on
    client + the period's start date, checked client-side."""
    status, res = call("GET", f"/Api/rentals/Booking?filters[client__eq]={urllib.parse.quote(client_ref)}&items=100")
    if status != 200:
        return None
    for row in res.get("data") or []:
        if (row.get("data") or {}).get("dates", {}).get("start") == start:
            return row["meta"]["id"]
    return None


booking_count = 0
for co_idx, start, end, st, notes, lines in BOOKINGS:
    client_ref = f"clients.Company.{company_ids[co_idx]}"
    booking_id = find_booking(client_ref, start)
    if booking_id:
        status, res = call("GET", f"/Api/rentals/Booking/{booking_id}")
        cur = (res.get("data") or {}).get("status")
    else:
        # Every booking starts as a draft. The confirmed/returned states are
        # reached through the named actions below, so the equipment hook —
        # not this script — marks the items out and back.
        booking_id = created("/Api/rentals/Booking", {
            "client": client_ref,
            "dates": {"start": start, "end": end},
            "status": "draft",
            "notes": notes,
        })
        cur = "draft"
    status, res = call("GET", f"/Api/rentals/Booking/{booking_id}/lines")
    if not (res.get("data") or []):
        for serial, qty, price in lines:
            created(f"/Api/rentals/Booking/{booking_id}/lines", {
                "item": f"equipment.Item.{item_ids[serial]}",
                "quantity": qty,
                "price": {"value": f"{price:.2f}", "currency": "EUR"},
            })
    if st in ("confirmed", "returned") and cur == "draft":
        call("POST", f"/Api/rentals/Booking/{booking_id}/confirm", {})
        cur = "confirmed"
    if st == "returned" and cur == "confirmed":
        call("POST", f"/Api/rentals/Booking/{booking_id}/mark_returned", {})
    booking_count += 1
print(f"bookings: {booking_count} (anchor {ANCHOR})")

# ── equipment: maintenance tickets ───────────────────────────────────────────────────
TICKETS = [
    ("GEN-20-A", "Pull cord snaps on the second pull. Starts but idles rough.", "diagnosing", lucia_id, tom_id),
    ("LA-SPK-A", "Left top box drops out above 14 kHz — likely driver.", "waiting_parts", lucia_id, nadia_id),
    ("TN-10015-A", "Two eyelets torn on the door wall after the storm booking.", "reported", lucia_id, tom_id),
    ("MIX-32-A", "Fader 12 crackles when moved. Needs contact cleaner.", "diagnosing", lucia_id, ravi_id),
    ("SUB-18-B", "Castor wheel seized; cabinet scratches on transport.", "fixed", lucia_id, lucia_id),
]
ticket_count = 0
for serial, problem, st, assignee, reporter in TICKETS:
    item_ref = f"equipment.Item.{item_ids[serial]}"
    existing = find("/Api/equipment/MaintenanceTicket", "item", item_ref)
    if not existing:
        created("/Api/equipment/MaintenanceTicket", {
            "item": item_ref,
            "problem": problem,
            "status": st,
            "assignee": f"iam.Account.{assignee}",
            "reported_by": f"iam.Account.{reporter}",
        })
    ticket_count += 1
print(f"tickets: {ticket_count}")

# ── done. The hook marked the confirmed bookings' items out, and the
#    returned bookings' items back in — check the warehouse board. ─────────
print("done")
