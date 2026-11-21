#!/usr/bin/env python3
"""Waechter fuer den Quelltext (laeuft in build.sh). Exit 1 bei Verstoss.
 1. Keine losen Zahlen ausserhalb Theme.swift: `size: <zahl>`, `cornerRadius: <zahl>`, `opacity(0.<zahl>)`.
    Einzelne Ausnahme: `// lint:allow` in derselben Zeile. Ganze Dateien nur in ALLOW_FILES (mit Grund).
 2. Hinweistexte (lang, grau) muessen umbrechen duerfen: ThemeNote / .themeNote() oder fixedSize.
 3. Keine .transition(.move / .opacity) (Falle 26: gleitet ueber Nachbarn); Klappen laufen ueber ThemeFold.
Aufruf: python3 tools/lint.py [--root <ordner mit *.swift>]"""
import re, glob, sys, os
root = "Sources/RecBlitz"
if "--root" in sys.argv: root = sys.argv[sys.argv.index("--root") + 1]
ALLOW_FILES = {}   # Dateiname -> Grund (leer: keine Ausnahmen)
bad = []
for path in sorted(glob.glob(os.path.join(root, "*.swift"))):
    name = os.path.basename(path)
    lines = open(path).read().split("\n")
    for i, line in enumerate(lines):
        code = line.split("//")[0] if "lint:allow" not in line else ""
        if not code.strip():
            continue
        if name != "Theme.swift" and name not in ALLOW_FILES:
            if re.search(r"size: [0-9]|cornerRadius: [0-9]|opacity\(0\.[0-9]", code):
                bad.append(f"{path}:{i+1}  lose Zahl (Theme-Name benutzen): {line.strip()[:90]}")
        if re.search(r"\.transition\(\.(move|opacity)", code):
            bad.append(f"{path}:{i+1}  .transition(.move/.opacity): ThemeFold benutzen")
        if "Theme.muted" in code and "ThemeNote" not in code and "themeNote" not in code:
            block = "\n".join(l for l in lines[max(0, i - 3):i + 1] if not l.strip().startswith("//") and "systemName" not in l)
            literals = [t for t in re.findall(r'"([^"]{2,})"', block) if "\\(" not in t]
            if max((len(t) for t in literals), default=0) >= 45:
                window = "\n".join(lines[i:i + 3])
                if "fixedSize" not in window and "lineLimit" not in window and "themeNote" not in block:
                    bad.append(f"{path}:{i+1}  langer Hinweistext ohne Umbruch (ThemeNote): {literals[0][:50]}")
if bad:
    print("!! LINT: Verstoesse")
    for b in bad: print("   " + b)
    sys.exit(1)
print("    Lint ok: keine losen Zahlen ausserhalb Theme.swift, Hinweistexte brechen um, keine Move-Transitions")
