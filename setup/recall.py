"""recall.py - search the CONVERSATION tier of canon: transcripts/rendered/.

THE PROBLEM THIS SOLVES (Paul, 2026-08-02):
  "The transcripts and losing their nuance/feel to compression is hard for me, so
   anything that might blunt that, or even negate it entirely, is a welcome change."

  transcripts/INDEX.md already maps each transcript to the PROJECT it feeds, which
  answers "which session was about the dashboard?". It cannot answer "find me the
  moment we worked out the disc-grime thing" or "what did Paul actually say about
  why he keeps the TeraStation?" - and that second class of question is where the
  nuance lives.

  This is the transcript-tier twin of setup/why.sh (STANDARDS 4B). Same doctrine:
  do NOT promote 4.6 MB of conversation into the loaded tier. Index it and query
  it on demand.

WHY THE UNIT OF RETRIEVAL IS A TURN, NOT A LINE:
  grep hands back a line, and a line out of a conversation is exactly the nuance
  loss this is meant to fix. So matches are returned as whole speaker turns, with
  who said it and when. -c widens that to the full exchange (Paul's turn plus the
  reply it drew), which is usually what someone actually wants to re-read.

USAGE
  py setup/recall.py <keywords>       search every turn (multiple words = AND)
  py setup/recall.py -p <keywords>    PAUL'S turns only - his framings and decisions
  py setup/recall.py -c <keywords>    show the full exchange around each hit
  py setup/recall.py -f <keywords>    full turn text, no truncation
  py setup/recall.py -l               table of contents: every session, dated

EXAMPLES  (all four verified against the live archive 2026-08-02)
  py setup/recall.py -p terastation     # why he keeps hardware that's been good to him
  py setup/recall.py -c froggy          # the exchange, not just the line
  py setup/recall.py read error         # broad -> returns the MAP of where the hits are
  py setup/recall.py -l                 # every session, dated, with volume

⚠️ SEARCH THE WORDS THAT WERE SAID, NOT CANON'S SUMMARY OF THEM.
  canon says "disc grime" and "lying instruments"; the session said "cleaned the
  disc" and "read error". 'grime' returns nothing. This gap is the single most
  likely reason a search comes back empty - try the phrasing someone would have
  typed in the moment, not the phrasing the lesson was written up in afterwards.

  AND is evaluated WITHIN ONE TURN, so extra words narrow hard: 'read error'
  alone finds 27, 'read error cleaned' finds 0 because nobody said both in a
  single message. To narrow, prefer -p (Paul's turns only) over more words.
"""
import os
import re
import sys

# Windows consoles default to cp1252, and BOTH the transcript text and any emoji
# markers are outside it -- printing either raises UnicodeEncodeError and kills the
# run mid-result. Transcript bodies always contain non-ASCII (em dashes, arrows,
# emoji), so this is mandatory, not cosmetic. Same family as STANDARDS 11B.
# Speaker markers below are deliberately ASCII so output stays readable even when
# the console silently degrades a character to '?'.
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except (AttributeError, OSError):
    pass

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RENDERED = os.path.join(ROOT, "transcripts", "rendered")

# "## 👤 Paul  ·  2026-07-11 14:23"  /  "## 🤖 Claude"  - date+time optional
SPEAKER = re.compile(r"^##\s+(?:\W*\s*)?(Paul|Claude)\s*(?:·\s*([\d-]+)\s*([\d:]+)?)?\s*$")


def sessions():
    if not os.path.isdir(RENDERED):
        sys.exit("no transcripts/rendered/ - nothing to search")
    return sorted(f for f in os.listdir(RENDERED) if f.endswith(".md"))


def turns(fname):
    """Yield (speaker, date, text) per turn. Date carries forward when a header omits it."""
    path = os.path.join(RENDERED, fname)
    with open(path, encoding="utf-8", errors="replace") as fh:
        lines = fh.read().splitlines()
    cur_sp = cur_dt = None
    buf = []
    last_dt = ""
    # session start date from the header table, so early turns aren't dateless
    for ln in lines[:20]:
        m = re.search(r"\|\s*Started\s*\|\s*([\d-]+)", ln)
        if m:
            last_dt = m.group(1)
            break
    for ln in lines:
        m = SPEAKER.match(ln)
        if m:
            if cur_sp:
                yield cur_sp, cur_dt, "\n".join(buf).strip()
            cur_sp = m.group(1)
            cur_dt = m.group(2) or last_dt
            if m.group(2):
                last_dt = m.group(2)
            buf = []
        elif cur_sp:
            buf.append(ln)
    if cur_sp:
        yield cur_sp, cur_dt, "\n".join(buf).strip()


def excerpt(text, words, full=False, width=420):
    if full:
        return text
    low = text.lower()
    pos = min((low.find(w) for w in words if low.find(w) >= 0), default=0)
    start = max(0, pos - width // 3)
    end = min(len(text), start + width)
    out = text[start:end].strip()
    return ("…" if start > 0 else "") + out + ("…" if end < len(text) else "")


def show(fname, sp, dt, text, words, full):
    icon = "[PAUL]  " if sp == "Paul" else "[Claude]"
    print(f"  {icon} {dt or '?'}  --  {fname[:56]}")
    for ln in excerpt(text, words, full).splitlines():
        print(f"      {ln}")
    print()


def main():
    args = sys.argv[1:]
    if not args or args[0] in ("-h", "--help"):
        print(__doc__)
        return

    mode = ""
    if args[0] in ("-p", "-c", "-f", "-l", "-a"):
        mode, args = args[0], args[1:]

    if mode == "-l":
        print("Session archive - transcripts/rendered/\n")
        for f in sessions():
            with open(os.path.join(RENDERED, f), encoding="utf-8", errors="replace") as fh:
                head = fh.read(1600)
            vol = re.search(r"\|\s*Volume\s*\|\s*([^|]+)\|", head)
            ttl = head.lstrip().split("\n", 1)[0].lstrip("# ").strip()
            print(f"  {f[:10]}  {ttl[:62]}")
            print(f"              {f}")
            if vol:
                print(f"              {vol.group(1).strip()}")
            print()
        return

    if not args:
        sys.exit("give me something to search for")
    words = [w.lower() for w in args]

    found = []          # (file, speaker, date, text, prev_turn)
    for f in sessions():
        prev = None
        for sp, dt, text in turns(f):
            low = text.lower()
            if all(w in low for w in words) and not (mode == "-p" and sp != "Paul"):
                found.append((f, sp, dt, text, prev))
            prev = (sp, dt, text)

    if not found:
        print(f"nothing matched {' '.join(words)!r}.")
        print()
        print("Transcripts use the words that were SAID, not canon's later summary of")
        print("them -- 'grime' finds nothing, 'cleaned the disc' finds the same hunt.")
        print("Search for what someone would have typed at the time.")
        print("  broader term       py setup/recall.py <one word>")
        print("  which sessions     py setup/recall.py -l")
        return

    # A wide search dumping 200 turns is the nuance problem wearing a different hat.
    # Over the threshold, hand back the MAP first (which sessions, how many, when)
    # so the next query can be aimed. Paul: "I wouldn't know what I don't know
    # without a way to index and reference quickly."
    BROAD = 12
    if len(found) > BROAD and mode != "-a":
        print(f"{len(found)} matches for {' '.join(words)!r} -- too many to read. Where they are:\n")
        tally = {}
        for f, sp, dt, _, _ in found:
            k = tally.setdefault(f, {"n": 0, "paul": 0, "first": dt, "last": dt})
            k["n"] += 1
            k["paul"] += 1 if sp == "Paul" else 0
            if dt:
                k["last"] = dt
                k["first"] = min(k["first"] or dt, dt)
        for f, k in sorted(tally.items(), key=lambda kv: -kv[1]["n"]):
            span = k["first"] if k["first"] == k["last"] else f"{k['first']} -> {k['last']}"
            print(f"  {k['n']:>4} hits ({k['paul']} from Paul)   {span}")
            print(f"       {f}")
        print()
        print("Narrow it:  -p (Paul's turns only)  |  -a to dump all")
        print("  NB: AND is within ONE turn, so extra words narrow hard -- prefer -p.")
        return

    for f, sp, dt, text, prev in found:
        if mode == "-c" and prev and prev[0] != sp:
            show(f, prev[0], prev[1], prev[2], words, False)
        show(f, sp, dt, text, words, mode == "-f")
    scope = "Paul's turns" if mode == "-p" else "all turns"
    print(f"— {len(found)} match(es) in {scope} across {len(sessions())} sessions")


if __name__ == "__main__":
    main()
