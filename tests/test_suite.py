#!/usr/bin/env python3
"""What a stranger can check without my vendor accounts.

Deliberately narrow. These are not unit tests of the measurements: the numbers
are pinned by evals/labels.csv and checked by evals/derive.py, which this suite
runs. What is tested here is the property the repo kept getting wrong, which is
that a thing can announce failure and still report success.

    python3 -m pytest tests/ -v
    python3 tests/test_suite.py          # same checks, no pytest needed
"""
import ast
import json
import os
import re
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROBES = os.path.join(ROOT, "probes")


def probe_files():
    return sorted(f for f in os.listdir(PROBES) if f.endswith(".py"))


def run(args, timeout=90):
    return subprocess.run([sys.executable] + args, cwd=ROOT, capture_output=True,
                          text=True, timeout=timeout)


# --- the suite compiles ------------------------------------------------------

def test_every_probe_parses():
    """A probe that does not compile cannot be a gate, however good its docstring."""
    for name in probe_files():
        path = os.path.join(PROBES, name)
        with open(path) as fh:
            ast.parse(fh.read(), filename=path)


# --- no entrypoint may crash instead of explaining itself --------------------

def test_no_probe_tracebacks_on_bare_invocation():
    """README claims probes explain themselves with no arguments.

    Four of them used to raise IndexError instead. A traceback is not an
    explanation, so this asserts the absence of one rather than the presence of
    any particular wording.
    """
    broken = []
    for name in probe_files():
        r = run([os.path.join("probes", name)])
        blob = r.stdout + r.stderr
        if "Traceback (most recent call last)" in blob:
            broken.append(f"{name}: traceback on no args")
    assert not broken, "probes crash instead of printing usage: " + "; ".join(broken)


def test_bare_invocation_never_claims_success_while_failing():
    """The failure this repo keeps rediscovering: printing an error, exiting 0.

    A probe with no input has not measured anything. If it exits 0 a shell
    caller reads that as a pass, which is exactly how a missing file becomes a
    silent approval.
    """
    liars = []
    for name in probe_files():
        r = run([os.path.join("probes", name)])
        said_usage = re.search(r"usage[: ]", (r.stdout + r.stderr), re.I)
        if said_usage and r.returncode == 0:
            liars.append(f"{name}: printed usage but exited 0")
    assert not liars, "; ".join(liars)


# --- the derivation is the product ------------------------------------------

def test_derive_runs_clean():
    r = run([os.path.join("evals", "derive.py")])
    assert r.returncode == 0, (
        f"evals/derive.py exited {r.returncode}\n{r.stdout}\n{r.stderr}")


def derive_json():
    r = run([os.path.join("evals", "derive.py"), "--json"])
    return json.loads(r.stdout)


def test_derive_json_shape():
    data = derive_json()
    for key in ("gates", "reproduced", "derived", "authored", "refuted", "n_gating"):
        assert key in data, f"derive --json missing {key}"
    assert data["refuted"] == 0, (
        f"{data['refuted']} threshold(s) sit outside their own labelled interval")
    assert data["derived"] > 0, "no threshold is backed by a labelled pass/reject pair"
    assert data["reproduced"], "no labelled row ships pixels, so nothing is reproducible"
    for row in data["reproduced"]:
        assert row.get("ok"), f"{row['item']} did not reproduce"


WORDS = {1: "one", 2: "two", 3: "three", 4: "four", 5: "five", 6: "six", 7: "seven",
         8: "eight", 9: "nine", 10: "ten", 11: "eleven", 12: "twelve", 13: "thirteen",
         14: "fourteen", 15: "fifteen", 16: "sixteen", 17: "seventeen", 18: "eighteen"}


def test_documented_counts_match_the_tool():
    """EVERY stated count in the docs must equal what derive.py prints.

    An earlier version of this test named six exact strings. That was not enough,
    and an adversarial pass proved it: move the real count, update only the six
    surfaces the test names, and the suite stays green while the README asserts
    five derived plus ten authored out of a total of fifteen that no longer adds
    up, and quotes a line derive.py no longer prints.

    So this scans instead of matching fixed needles. Any sentence anywhere in
    these files that states one of these counts is checked, including ones added
    after this test was written. A pattern with `required` also has to appear at
    least once, so deleting the sentence is not a way to pass.
    """
    data = derive_json()
    d, a, m = data["derived"], data["authored"], data["n_gating"]
    assert d + a == m, (
        f"derive.py is internally inconsistent: {d} derived + {a} authored != {m} gating")
    num = {v: k for k, v in WORDS.items()}

    def val(tok):
        tok = tok.strip().lower()
        return int(tok) if tok.isdigit() else num.get(tok)

    # (regex, tuple of expected values per capture group, required)
    checks = [
        (r"(\w+) of the (\w+) named gating thresholds", (d, m), True),
        (r"and (\d+) of (\d+) named gating thresholds derived", (d, m), True),
        (r"(\d+)%2F(\d+)_derived", (d, m), True),
        (r"(\d+) of (\d+) NAMED gating thresholds are DERIVED", (d, m), True),
        (r"\*\*(\w+) of (\w+)\.\*\*", (d, m), True),
        # Required only while some threshold is still authored; the sentence
        # has no sensible form at zero.
        (r"[Tt]he other (\w+) were typed by hand", (a,), a > 0),
        (r"(\d+) are AUTHORED", (a,), True),
        (r"is one of the (\w+):", (d,), False),
    ]
    problems = []
    for rel in ("README.md", "docs/EVALS.md"):
        text = open(os.path.join(ROOT, rel)).read()
        for pattern, expected, required in checks:
            found = re.findall(pattern, text)
            for hit in found:
                groups = hit if isinstance(hit, tuple) else (hit,)
                got = tuple(val(g) for g in groups)
                if got != expected:
                    problems.append(
                        f"{rel}: {pattern!r} says {got}, derive.py says {expected}")
            if required and not found and rel == "README.md":
                problems.append(f"README.md: no sentence matches {pattern!r}")
    assert not problems, (
        f"derive.py reports {d} derived / {a} authored / {m} gating. "
        + "; ".join(problems))



def test_no_retired_claim_survives_on_any_surface():
    """The landing page is more than README.md, and the rest is not text-diffable.

    Two claims were retired: that every threshold is derived, and that all four
    gates block. Both lived in FIVE places, including an SVG text node and its
    own aria-label twin. Fixing the visible pixels while leaving the accessible
    text is not fixing it.

    This used to matter more than a normal staleness check, because both SVGs
    were written by a generator that was NOT in this repository: regenerating
    from that private tree would have silently restored both claims with nothing
    to notice. tools/render_diagrams.py closes that hole. Both SVGs are
    generated here now and byte-checked in CI.

    This test stays, and not merely out of caution. A retired CLAIM is a
    sentence, not a number, so no count check can see one; and docs/ and
    README.md are written by hand and always will be. This is the check that
    reads the words.
    """
    # Regexes, not substrings. The first version used bare substrings and flagged
    # two correct sentences: "holds each derived constant inside the interval" and
    # a legend line defining which gates block. A staleness check that cries wolf
    # gets muted, so these match the retired CLAIM shapes only.
    retired = [
        (r"every threshold (?:in|comes|derived|is derived)",
         "the count is whatever derive.py prints, and is not all of them"),
        (r"never typed", "ten of the fifteen were typed by hand"),
        (r"each derived from", "not every probe threshold is derived from labels"),
        (r"probes,\s*each derived", "not every probe threshold is derived"),
        (r"(?:\d+|four)\s+blocking\s+(?:gates|guards)", "three of the four fail open"),
        (r"gates,\s*blocking\b", "three of the four fail open"),
    ]
    surfaces = []
    for sub in ("assets", "docs"):
        d = os.path.join(ROOT, sub)
        for f in sorted(os.listdir(d)):
            if f.endswith((".svg", ".html", ".md")):
                surfaces.append(os.path.join(sub, f))
    surfaces.append("README.md")

    hits = []
    for rel in surfaces:
        text = open(os.path.join(ROOT, rel), errors="ignore").read().lower()
        # The README narrates what it USED to say; that sentence is history, not a claim.
        text = text.replace("used to say every threshold was derived and none was", "")
        text = text.replace("this page used to say every threshold", "")
        for pattern, why in retired:
            m = re.search(pattern, text)
            if m:
                hits.append(f"{rel} still says {m.group(0)!r} ({why})")
    assert not hits, "retired claims are back: " + "; ".join(hits)


def test_labelled_pixels_exist():
    """A label pointing at a file that is not in the repo is a claim, not evidence."""
    import csv
    path = os.path.join(ROOT, "evals", "labels.csv")
    with open(path) as fh:
        body = [ln for ln in fh if not ln.lstrip().startswith("#")]
    missing = []
    for row in csv.DictReader(body):
        px = (row.get("pixels") or "").strip()
        if px and px != "withheld" and not os.path.exists(os.path.join(ROOT, px)):
            missing.append(px)
    assert not missing, "labels reference missing files: " + ", ".join(missing)


# --- constants must be live --------------------------------------------------

def test_no_dead_gating_constants():
    """A constant nobody reads still gets read by a human, who then believes it.

    spasm_probe carried FAIL_RATIO and WARN_RATIO long after the gate stopped
    using them, and its docstring described the verdicts they implied. This
    catches the next one mechanically.
    """
    dead = []
    for name in probe_files():
        path = os.path.join(PROBES, name)
        with open(path) as fh:
            tree = ast.parse(fh.read(), filename=path)
        assigned, loaded = {}, set()
        for node in ast.walk(tree):
            # Covers `X = 1` and the annotated `X: float = 1`, which a regex on
            # `^NAME\s*=` silently misses.
            targets = []
            if isinstance(node, ast.Assign):
                targets = [t for t in node.targets if isinstance(t, ast.Name)]
            elif isinstance(node, ast.AnnAssign) and isinstance(node.target, ast.Name):
                targets = [node.target]
            for t in targets:
                if t.id.isupper() and len(t.id) >= 2:
                    assigned.setdefault(t.id, node.lineno)
            if isinstance(node, ast.Name) and isinstance(node.ctx, ast.Load):
                loaded.add(node.id)
        for const, line in sorted(assigned.items()):
            # AST sees real reads only, so a name that survives merely by being
            # mentioned in a docstring or an f-string no longer counts as used.
            if const not in loaded:
                dead.append(f"{name}:{const}:{line}")
    assert not dead, "assigned but never read: " + ", ".join(dead)


def test_scanner_honours_per_rule_case_flags():
    """A project rule must be able to opt into case-insensitive matching.

    A name is not case-stable in prose. The same identity token gets written
    capitalised, lower, and SHOUTED in a comment, and every project rule ran
    case-SENSITIVE because apply_rule_table never passed the flags argument
    run_rule already accepted. So a rule spelling one capitalisation let the
    others through and reported clean. That is the exact failure this
    repository is about: a check announcing success on input it never examined.

    The negative half carries equal weight. A blanket -i would make the
    built-in identifier rules (tracker keys, chat object ids, both defined as
    uppercase shapes) start matching ordinary lowercase prose, so this asserts
    an unflagged rule stays case-sensitive.

    Line 4 is the word-boundary control. \\b is what keeps a rule from firing on
    every longer word that contains the token, and a scanner whose grep engine
    silently ignores \\b reports a clean audit of nothing.
    """
    script = os.path.join(ROOT, "tools", "pii_scan.sh")
    with tempfile.TemporaryDirectory(dir=ROOT) as tmp:
        rules = os.path.join(tmp, "rules.txt")
        target = os.path.join(tmp, "target.txt")
        with open(rules, "w") as fh:
            # SEVERITY \t CLASS \t LABEL \t REGEX \t FLAGS; absent FLAGS means
            # case-sensitive, which is what every identifier rule relies on.
            fh.write("BLOCKER\tCLASS5-WORKPLACE\tname-any-case\t\\bzebra\\b\t-i\n")
            fh.write("BLOCKER\tCLASS5-WORKPLACE\tid-exact-case\t\\bZQ[0-9]{4}\\b\n")
        with open(target, "w") as fh:
            fh.write("ZEBRA shouted\nzebra lower\nZebra title\n"
                     "zebrafish is a longer word\nZQ1234 identifier\nzq1234 not one\n")
        env = dict(os.environ, PII_CONTEXT_FILE=rules, PII_SCAN_SOFT="1")
        r = subprocess.run(["bash", script, target], cwd=ROOT, env=env,
                           capture_output=True, text=True, timeout=90)
        out = r.stdout + r.stderr
        hits = {}
        for line in out.splitlines():
            parts = line.strip().split(":")
            if len(parts) >= 5 and parts[-1] in ("name-any-case", "id-exact-case"):
                if parts[1].isdigit():
                    hits.setdefault(parts[-1], set()).add(int(parts[1]))
        assert hits.get("name-any-case") == {1, 2, 3}, (
            "a rule carrying -i must match every capitalisation (lines 1, 2, 3) "
            "and must not match the longer word on line 4; got lines "
            f"{sorted(hits.get('name-any-case', []))}\n" + out)
        assert hits.get("id-exact-case") == {5}, (
            "a rule with no flags must stay case-sensitive, or the built-in "
            "uppercase identifier rules start firing on ordinary prose; "
            f"expected only line 5, got {sorted(hits.get('id-exact-case', []))}\n"
            + out)


def test_commit_message_hook_enforces_the_same_table_the_scanner_does():
    """The commit message hook had no test, which is why it failed in silence.

    The rule table grew an optional fifth column. This hook still read four
    fields, so every regex became pattern, tab, flag and matched nothing. It
    kept running and kept printing its banner while passing everything,
    including a message carrying a word the file scanner refuses to publish.
    A gate with no test cannot tell you it has stopped being a gate, and this
    one stayed down for hours before anyone ran it by hand.

    Both directions are asserted, because each has already been wrong once.
    A flagged rule must catch every capitalisation, or a shouted name walks
    through. An unflagged rule must NOT match the wrong case, or a brand name
    that doubles as an ordinary English word turns every honest sentence into
    a finding, and a gate that cries wolf gets bypassed rather than answered.
    """
    hook = os.path.join(ROOT, ".githooks", "commit-msg")
    assert os.access(hook, os.X_OK), "the hook is not executable, so git never runs it"

    with tempfile.TemporaryDirectory(dir=ROOT) as tmp:
        subprocess.run(["git", "init", "-q", tmp], check=True, capture_output=True)
        os.makedirs(os.path.join(tmp, "tools"))
        with open(os.path.join(tmp, "tools", "pii_context.txt"), "w") as fh:
            # FIVE columns on the first rule, FOUR on the second. A hook that
            # reads the wrong number of fields fails one of these two.
            fh.write("BLOCKER\tCLASS5-WORKPLACE\tname-any-case\t\\bzebra\\b\t-i\n")
            fh.write("HIGH\tCLASS5-WORKPLACE\tbrand-exact-case\t\\bZebraCorp\\b\n")

        def run_hook(text):
            msg = os.path.join(tmp, "MSG")
            with open(msg, "w") as fh:
                fh.write(text)
            r = subprocess.run(["bash", hook, msg], cwd=tmp, capture_output=True,
                               text=True, timeout=30)
            return r.returncode, r.stdout + r.stderr

        rc, out = run_hook("Fix the ZEBRA handling in the renderer\n")
        assert rc != 0, ("a rule carrying -i must block every capitalisation; the "
                         "shouted spelling is the one that leaked\n" + out)
        assert "name-any-case" in out, "the finding must name its rule: " + out

        rc, out = run_hook("Fix the zebracorp handling\n")
        assert rc == 0, ("an unflagged rule must not match the wrong case, or an "
                         "ordinary word becomes a finding on every commit\n" + out)

        rc, out = run_hook("Rename a variable and tighten a docstring\n")
        assert rc == 0, "a clean message must pass: " + out

        rc, out = run_hook("Fix the ZEBRA handling\n")
        assert "ZEBRA" not in out, (
            "the hook printed the matched text. A gate that echoes the string "
            "into your terminal has moved it, not caught it:\n" + out)


def _main():
    fns = [(k, v) for k, v in sorted(globals().items())
           if k.startswith("test_") and callable(v)]
    failed = 0
    for name, fn in fns:
        try:
            fn()
            print(f"ok    {name}")
        except AssertionError as exc:
            failed += 1
            print(f"FAIL  {name}\n        {exc}")
        except Exception as exc:                      # noqa: BLE001
            failed += 1
            print(f"ERROR {name}\n        {type(exc).__name__}: {exc}")
    print(f"\n{len(fns) - failed} passed, {failed} failed")
    return 1 if failed else 0



def test_judge_calibration_set_matches_the_rubric():
    """The README quotes 42 scenes, 16 FAIL and 26 PASS, from the judge rubric. The set ships beside it."""
    import json
    rubric = json.load(open(os.path.join(ROOT, "evals", "judge-rubric.json")))
    calib = json.load(open(os.path.join(ROOT, "evals", "judge-calibration.json")))
    entries = [v for v in calib.values() if isinstance(v, list)][0]
    labels = [e["label"] for e in entries]
    assert (len(entries), labels.count("FAIL"), labels.count("PASS")) == (42, 16, 26), labels
    stated = rubric["groundedness"]["calibration"]["set"]
    assert "42" in stated and "16 FAIL" in stated and "26 PASS" in stated, stated



def test_system_map_matches_its_generator():
    """The system map is output, not a drawing. A hand edit to the SVG fails here."""
    r = run(["tools/render_map.py", "--check"])
    assert r.returncode == 0, r.stdout + r.stderr


def test_readme_process_cards_match_the_ledgers():
    """Each redo row on the page, keyed by ad and engine, is what the landings and requests say.

    The last gated master per ad in a batch is the one that shipped. Earlier rows
    are the rebuilds the page counts but does not score.
    """
    import json
    brands = {"orchard": "Orchard Hill Coffee", "lantern": "Lantern Street",
              "harbor": "Harbor Lane Realty", "slowroad": "Slow Road Travel"}
    labels = {"alibaba/wan-3.0/text-to-video": "Wan 3.0",
              "bytedance/seedance-2.0/text-to-video": "Seedance 2.0",
              "google/gemini-omni-flash": "Omni Flash"}
    omni_engine = "google/gemini-omni-flash"

    def rows(batch, name):
        out = []
        for line in open(os.path.join(ROOT, "shoots", batch, name)):
            if line.strip():
                out.append(json.loads(line))
        return out

    def shipped(batch):
        last = {}
        for row in rows(batch, "landings.jsonl"):
            if row.get("kind") == "gated master":
                last[row["ad"]] = row
        return last

    def reading(row):
        mouth = row["mouth"]
        status = mouth.split()[0]
        lag = mouth.split("lag ")[1].split(",")[0].split(";")[0].strip()
        lag = lag.replace("+0.00", "0.00").replace("-0.00", "0.00")
        eye = ", eye approved" if "eye approved" in mouth else ""
        return f"{status}, {lag} s{eye}"

    def version(row):
        return "v" + re.search(r"-final-v(\d+)\.mp4$", row["master"]).group(1)

    def renders(batches, ad, engine):
        return sum(1 for b in batches for r in rows(b, "requests.jsonl")
                   if r["scene"].startswith(ad + "-") and r.get("engine") == engine)

    def table(readme, first_cell):
        block = readme.split("\n| " + first_cell + " |")[1].split("\n\n")[0]
        lines = ("| " + first_cell + " |" + block).split("\n")
        return [[c.strip() for c in line.strip().strip("|").split("|")]
                for line in lines if line.startswith("|") and not line.startswith("|:")]

    winner, omni = shipped("ads5"), shipped("ads6-omni")
    assert sorted(winner) == sorted(omni) == sorted(brands), (sorted(winner), sorted(omni))
    for row in list(winner.values()) + list(omni.values()):
        assert row["captions"] == "PASS 5 cues" and row["drift_ms"] == 0, row
    # the engine behind each ad's winner leg is whatever the last round requested for it
    engines = {}
    for r in rows("ads5", "requests.jsonl"):
        engines[r["scene"].split("-")[0]] = r["engine"]
    rounds = ("ads3", "ads4", "ads5")

    readme = open(os.path.join(ROOT, "README.md")).read()
    orchard = {r[0]: r[1:] for r in table(readme, "Process record, Orchard Hill Coffee")}
    assert orchard["Process record, Orchard Hill Coffee"] == [labels[engines["orchard"]], "Omni Flash"]
    assert orchard["Scene renders in the ledger across the rounds, re-rolls included"] == [
        str(renders(rounds, "orchard", engines["orchard"])),
        str(renders(("ads6-omni",), "orchard", omni_engine))], orchard
    assert orchard["Caption gate on the shipped master"] == ["PASS, 5 cues"] * 2
    assert orchard["Closer video against its audio placement"] == ["0 ms"] * 2
    assert orchard["Mouth sync on the shared closer"] == [reading(winner["orchard"]), reading(omni["orchard"])]
    assert orchard["Master that shipped"] == [version(winner["orchard"]), version(omni["orchard"])]

    others = table(readme, "The other three spots")[1:]
    assert [c[0].split(", ")[0] for c in others] == ["Lantern Street", "Harbor Lane Realty", "Slow Road Travel"], others
    for cells in others:
        brand, engine_label = cells[0].split(", ")
        ad = {v: k for k, v in brands.items()}[brand]
        assert engine_label == labels[engines[ad]], cells
        counts = f"{renders(rounds, ad, engines[ad])} and {renders(('ads6-omni',), ad, omni_engine)}"
        assert cells[1] == counts or cells[1].startswith(counts + ","), (cells, counts)
        assert reading(winner[ad]) == reading(omni[ad]) == cells[2], (cells, winner[ad]["mouth"], omni[ad]["mouth"])
        assert cells[3] == f"{version(winner[ad])} and {version(omni[ad])}", cells


def test_system_map_steps_match_the_process_table():
    """The map and the process table name the same seven steps in the same order."""
    import importlib.util
    spec = importlib.util.spec_from_file_location("render_map", os.path.join(ROOT, "tools", "render_map.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    drawn = [step[0] for step in mod.STEPS]
    readme = open(os.path.join(ROOT, "README.md")).read()
    table = readme.split("| Step | What it has to prove")[1].split("\n\n")[0].split("\n")[2:]
    written = [row.split("|")[1].strip() for row in table if row.startswith("|")]
    assert written == drawn, (written, drawn)



def test_loop_graph_steps_match_the_process_table():
    """The Mermaid loop graph names the same seven steps as the map and the process table, in order."""
    import importlib.util
    import re
    spec = importlib.util.spec_from_file_location("render_map", os.path.join(ROOT, "tools", "render_map.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    drawn = [step[0] for step in mod.STEPS]
    readme = open(os.path.join(ROOT, "README.md")).read()
    graph = readme.split("```mermaid")[1].split("```")[0]
    run = graph.split("subgraph RUN[")[1].split("\n    end")[0]
    graphed = [a or b for a, b in re.findall(r'\w+(?:\["([^"]+)"\]|\{"([^"]+)"\})', run)]
    assert graphed == drawn, (graphed, drawn)


if __name__ == "__main__":
    sys.exit(_main())
