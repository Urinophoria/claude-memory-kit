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
FAKE_GH_TOKEN = "gh" + "p_" + "A1b2C3d4E5f6G7h8I9j0K1l2M3n4O5p6Q7r8"

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
    ("- **Pro Pass: `subscriptionState=\"Active\"`**", [], ["subscriptionState"]),
    ("Both verifications pass: **forms-portal - all 9 edits clean**", [], ["forms-portal"]),
    ("first pass: re-render", [], ["re-render"]),
    ("the tests pass: everything", [], ["everything"]),
    # --- a first, too-loose pass/pw cut spared these; each must mask ---
    ("user `labadmin`, Pass: `Kx9#mQ2v`", ["Kx9#mQ2v"], ["labadmin"]),          # code span
    ("PW: **Hunter2!**", ["Hunter2!"], []),                                      # bold
    ("pw: #k8Lq2!vZ", ["k8Lq2!vZ"], []),                                         # markup-char opener
    ("| fw01 | PW: `Xk9#mQ2v` |", ["Xk9#mQ2v"], ["fw01"]),                       # table cell
    ("WiFi PW: `GuestNet2026`", ["GuestNet2026"], []),
    ("Pass: HunterGreen", ["HunterGreen"], []),                                  # mixed case, no digit
    ("Pass: purplemonkeydish", ["purplemonkeydish"], []),                        # 16 chars, one class
    ("first pass: password=\"Summer2026!\"", ["Summer2026!"], []),               # label nested in a value
    ("tests pass: `secret=Kx9#mQ2vLp7Zt`", ["Kx9#mQ2vLp7Zt"], []),
    ("pw: --password=\"Summer2026!\"", ["Summer2026!"], []),
    ("password: summer-fun-time", ["summer-fun-time"], []),                      # long labels keep the loose rule
    ("token: abcdefghijklmnopq", ["abcdefghijklmnopq"], []),
    ("password: `Zq7#Lm2xKp`", ["Zq7#Lm2xKp"], []),
    # ... while everyday 'pass:' prose still survives (flagging it stalled the fail-closed archive)
    ("Pro Pass: subscriptionState=\"Active\" again", [], ["subscriptionState"]),  # key="value", no markup
    ("pw: same-as-before", [], ["same-as-before"]),
    ("first pass: abcdefghijklmno", [], ["abcdefghijklmno"]),                    # 15 chars, one class: cold
    ("first pass: abcdefghijklmnop", ["abcdefghijklmnop"], []),                  # 16: hot (boundary)
    # --- the key="value" exemption must only cover a value that OPENS with a
    #     non-secret key; a credential followed by another attribute, or under a compound secret name, masks ---
    ("$cred = @{Pass=\"Hunter2!x\";User=\"labadmin\"}", ["Hunter2!x"], []),
    ("login(pw=\"Hunter2!x\",user=\"labadmin\")", ["Hunter2!x"], []),
    ("PW:\"Hunter2!x\",note=\"rotated\"", ["Hunter2!x"], []),
    ("pw: DB_PASSWORD=\"Hunter2!x\"", ["Hunter2!x"], []),
    ("pass: adminPassword='Hunter2!x'", ["Hunter2!x"], []),
    ("pass: --admin-password=\"Hunter2!x\"", ["Hunter2!x"], []),                # redacts AND rescans clean
    ("Pass: Password=\"Hunter2!x\"", ["Hunter2!x"], []),
    ("pw: $Password='Hunter2!x'", ["Hunter2!x"], []),
    ("pass: ghToken=\"" + FAKE_GH_TOKEN + "\"", [FAKE_GH_TOKEN], []),
    ("Season Pass: planState=\"Active\" renews", [], ["planState"]),
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

    # fail-closed: re-scanning redacted output finds nothing hot (what the hook gate relies on). Checked for
    # EVERY case plus the conn-string shapes, whose own mask once re-matched: one
    # 'scheme://user:[REDACTED]@host' in rendered/ stalled the archive and spawn-checkpoint begin.
    leaky = ["secret = " + FAKE_STRIPE + " and password = Winter_2026_Portal_Login",
             "ldap://binduser:" + "Zq7Lm2xKp" + "@dc01.example.invalid",
             "git remote https://deploy:" + "Kx9mQ2vLp7" + "@git.example.invalid/repo.git"]
    for s in leaky + [c[0] for c in CASES]:
        _h, red = rs.scan_text(s + "\n", redact=True)
        hits2, _ = rs.scan_text(red, redact=False)
        if any(h[3] for h in hits2):
            f += 1
            print(f"  FAIL | re-scan of redacted output still flags a secret (fail-closed broken): {red.strip()!r}")
        else:
            p += 1

    # Property: redaction is a fixpoint over GENERATED nested shapes (outer label x inner key x wrapper x
    # value). Hand-picked cases once all passed while dozens of realistic label/key pairs rescanned HOT.
    outers = ["pass: ", "Pass: ", "PW: ", "pw=", "first pass: ", "password: ", "token: ", "secret="]
    inners = ["", "password=", "Password=", "--admin-password=", "$Password=", "DB_PASSWORD=", "adminPassword=",
              "tokenName=", "api_key=", "user="]
    wraps = [("", ""), ("\"", "\""), ("'", "'"), ("`", "`"), ("**", "**"), ("(", ")"), ("@{x=", "}")]
    values = ["Hunter2!x", "HunterGreen", "purplemonkeydish", "hunter!!", "abc", FAKE_GH_TOKEN,
              "correct-horse-battery", "[REDACTED]"]
    bad_fix = 0
    for o in outers:
        for n in inners:
            for wl, wr in wraps:
                for val in values:
                    s = o + n + wl + val + wr
                    _h, red = rs.scan_text(s + "\n", redact=True)
                    if any(h[3] for h in rs.scan_text(red)[0]):
                        bad_fix += 1
                        if bad_fix <= 3:
                            print(f"  FAIL | not a fixpoint: {s!r} -> {red.strip()!r}")
    if bad_fix:
        f += 1
        print(f"  FAIL | {bad_fix} generated nested shapes rescan HOT after redaction")
    else:
        p += 1

    # An ALREADY-rendered line whose secret an older scanner masked must stay cold (a rule change that turns
    # an old render HOT stalls the fail-closed archive gate until someone re-renders it).
    for s in ("pass: tokenName=\"[REDACTED]\"", "pass: --admin-password=[REDACTED]", "Pass: `[REDACTED]`",
              "pw: user=\"labadmin\";Password=\"[REDACTED]\"", "ldap://binduser:[REDACTED]@dc01"):
        if any(h[3] for h in rs.scan_text(s + "\n")[0]):
            f += 1
            print(f"  FAIL | an already-masked line scans HOT: {s!r}")
        else:
            p += 1

    # Linear time: a long whitespace-free run dense with labels (the value lookahead made this quadratic).
    import time
    t0 = time.time()
    rs.scan_text("pass:" * 40000 + "\n", redact=True)
    if time.time() - t0 > 5:
        f += 1
        print(f"  FAIL | 200 KB label run took {time.time() - t0:.1f}s (quadratic scan?)")
    else:
        p += 1

    # strict mode (atoms-lint): no prose allowance for the short labels.
    for s in ("Pass: hunter!!", "pw: same-as-before"):
        if any(h[3] for h in rs.scan_text(s + "\n", strict=True)[0]):
            p += 1
        else:
            f += 1
            print(f"  FAIL | strict scan should flag {s!r}")

    print(f"\nredaction-test: {p} passed, {f} failed")
    return 1 if f else 0

if __name__ == "__main__":
    sys.exit(main())
