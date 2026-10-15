import io, sys
sys.stdout.reconfigure(encoding="utf-8", errors="replace")

OLD = '''    MD_NAME = "system-model.architecture-understanding.md"
    md_path = os.path.join(HERE, MD_NAME)
    if not os.path.isfile(md_path):
        fails.append("prose document missing: %s" % MD_NAME)
        stats["md_cites"] = 0
    else:
        found = scan(io.open(md_path, encoding="utf-8").read())
        stats["md_cites"] = len(found)
        for f, ln in sorted(found):
            if (f, int(ln)) not in ok_pairs:
                fails.append("%s cites unverified %s:%s" % (MD_NAME, f, ln))
'''

NEW = '''    md_files = sorted(f for f in os.listdir(HERE) if f.endswith(".md"))
    if not md_files:
        fails.append("no markdown artifact found next to the gate; nothing to scan")
        stats["md_cites"] = 0
    else:
        for MD_NAME in md_files:
            found = scan(io.open(os.path.join(HERE, MD_NAME), encoding="utf-8").read())
            stats["md_cites"] += len(found)
            for f, ln in sorted(found):
                if (f, int(ln)) not in ok_pairs:
                    fails.append("%s cites unverified %s:%s" % (MD_NAME, f, ln))
'''

for path, expect_n in (("cross_check.py", 1), ("add_prose_refs.py", 0)):
    raw = io.open(path, encoding="utf-8").read()
    n = raw.count(OLD)
    if n != expect_n:
        print("ABORT: %s has %d matches, expected %d" % (path, n, expect_n))
        sys.exit(1)
    if expect_n == 1:
        io.open(path, "w", encoding="utf-8", newline="\n").write(raw.replace(OLD, NEW))
        print("patched %s" % path)
