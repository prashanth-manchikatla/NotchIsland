import sys, re, pathlib
root = pathlib.Path(sys.argv[1])
count = 0
for p in root.rglob("*.swift"):
    s = p.read_text()
    if "#Preview" not in s:
        continue
    out, i = [], 0
    while True:
        m = re.search(r'(?m)^[ \t]*#Preview\b', s[i:])
        if not m:
            out.append(s[i:]); break
        start = i + m.start()
        out.append(s[i:start])
        j = s.index("{", start)
        # skip parenthesized args before brace
        depth, k = 0, j
        while True:
            c = s[k]
            if c == "{": depth += 1
            elif c == "}":
                depth -= 1
                if depth == 0: break
            k += 1
        k += 1
        if k < len(s) and s[k] == "\n": k += 1
        i = k; count += 1
    p.write_text("".join(out))
print("removed", count, "preview blocks")
