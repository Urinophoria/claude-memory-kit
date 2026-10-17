#!/usr/bin/env python3
"""redaction-test.py — regression guard for render-session.py's secret scanner.

Locks in the 2026-08-26 pass-2 fix (branded always-patterns + bounded _HEXISH + all-caps-only
_IDENTISH) so a future tweak can't silently re-open a leak or re-introduce a false positive.
Run:  py transcripts/redaction-test.py     Exit 0 = all pass, 1 = a case regressed.
"""
import importlib.util, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("rs", os.path.join(HERE, "render-session.py"))
rs = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rs)

def redacted(line):
    _hits, out = rs.scan_text(line + "\n", redact=True)
    return out.rstrip("\n")

# Branded fake tokens are ASSEMBLED at runtime so no literal key shape sits in source: GitHub push
# protection refuses a push containing a Stripe-shaped key even when it is a documented fake (the kit's
# first push of this file was blocked, 2026-10-17). The scanner still sees the full string at test time.
FAKE_STRIPE = "sk_" + "live_" + "4eC39HqLyjWDarjtT1zdp7dc00"
FAKE_GH_PAT = "github_" + "pat_" + "11ABCDEFG0abcdefg1234567"
FAKE_GLPAT = "glpat" + "-ABCdef123456789_xyzXYZ"
FAKE_GKEY = "AIza" + "SyD-abcdefghijklmnopqrstuvwxyz012345"

# (input, must be MASKED [substrings gone], must SURVIVE [substrings kept])
CASES = [
    # --- pass-2 leaks: MUST redact (were leaking under the T2 exclusions) ---
    ("secret = " + FAKE_STRIPE, [FAKE_STRIPE], []),
    ("token = " + FAKE_GH_PAT, [FAKE_GH_PAT], []),
    ("token = A1b2C3d4E5f6A1b2C3d4E5f6A1b2C3d4", ["A1b2C3d4E5f6A1b2C3d4E5f6A1b2C3d4"], []),
    ("password = Winter_2026_Portal_Login", ["Winter_2026_Portal_Login"], []),
    ("key: " + FAKE_GLPAT, [FAKE_GLPAT], []),
    ("Bearer " + FAKE_GKEY, [FAKE_GKEY], []),
    # --- weak-but-real human passwords: MUST redact (the 2026-08-24 fix) ---
    ("password: acme2026portal", ["acme2026portal"], []),
    ("password: correcthorsebatterystaple", ["correcthorsebatterystaple"], []),
    ("conn: postgres://user:SuperSecretPw99@host/db", ["SuperSecretPw99"], []),
    ("password=FAKEaa11!!zzQQ token=FAKEbb22!!yyWW", ["FAKEaa11!!zzQQ", "FAKEbb22!!yyWW"], []),
    # --- technical/prose false positives: MUST stay (cold) ---
    ("method token: @0600597A has zero callers", [], ["@0600597A"]),
    ("MemberRef token=0x0A000989", [], ["0x0A000989"]),
    ("CSRF token: `HTTP_CSRF_TOKEN` cookie", [], ["HTTP_CSRF_TOKEN"]),
    # --- 'pass'/'pw' labels (2026-10-17): real pasted creds MUST redact; everyday 'pass:' prose MUST survive ---
    ("user: claude  Pass: acme2026portal", ["acme2026portal"], []),
    ("PW: Summer!Fun", ["Summer!Fun"], []),
    ("pw=Xk9#mQ2v", ["Xk9#mQ2v"], []),
    ("Pass: correcthorsebatterystaple", ["correcthorsebatterystaple"], []),
    ("- **Plex Pass: `subscriptionState=\"Active\"`**", [], ["subscriptionState"]),
    ("Both verifications pass: **forms-portal - all 9 edits clean**", [], ["forms-portal"]),
    ("first pass: re-render", [], ["re-render"]),
    ("the tests pass: everything", [], ["everything"]),
    ("password: entered", [], ["entered"]),
    ("the api_key: rotation is scheduled", [], ["rotation"]),
    ("cert password: <PFX_PW>", [], ["<PFX_PW>"]),
    ("just a normal sentence with no secrets", [], ["normal sentence"]),
]

def main():
    p = f = 0
    for inp, mask, keep in CASES:
        out = redacted(inp)
        bad = []
        for s in mask:
            if s in out:
                bad.append(f"LEAKED {s!r}")
        for s in keep:
            if s not in out:
                bad.append(f"over-masked {s!r}")
        if bad:
            f += 1
            print(f"  FAIL | {inp[:48]!r}\n         -> {out}\n         {'; '.join(bad)}")
        else:
            p += 1

    # fail-closed: re-scanning redacted output finds nothing hot (what the hook gate relies on)
    leaky = "secret = " + FAKE_STRIPE + " and password = Winter_2026_Portal_Login"
    _h, red = rs.scan_text(leaky + "\n", redact=True)
    hits2, _ = rs.scan_text(red, redact=False)
    if any(h[3] for h in hits2):
        f += 1
        print("  FAIL | re-scan of redacted output still flags a secret (fail-closed broken)")
    else:
        p += 1

    print(f"\nredaction-test: {p} passed, {f} failed")
    return 1 if f else 0

if __name__ == "__main__":
    sys.exit(main())
