# Writes the README's Swift examples as one compilable file for the consumer
# package (check.sh). Each example becomes a function (or stays at file scope
# when it only declares types), with the few names the prose assumes
# (`window`, `session`, `rect`, `MyView`) supplied as parameters or stubs.
import re
import sys

readme, out = sys.argv[1], sys.argv[2]
blocks = re.findall(r"```swift\n(.*?)```", open(readme).read(), re.S)
imports, decls, funcs = {"import AppKit", "import FullPanelKit"}, [], []
for i, block in enumerate(blocks):
    if block.lstrip().startswith("// Package.swift"):
        continue  # manifest excerpt, not app code
    lines = block.splitlines()
    imports.update(l.strip() for l in lines if l.startswith("import "))
    body = "\n".join(l for l in lines if not l.startswith("import "))
    if re.match(r"\s*(@MainActor\s+)?(final\s+)?(class|struct)\b", body.strip()) and "\nlet " not in body:
        decls.append(f"// README example {i}\n{body}")
    else:
        funcs.append(f"// README example {i}\n@MainActor func readmeExample{i}(window: FullPanelWindow, "
                     f"session: FullPanelSession, rect: NSRect) throws {{\n{body}\n}}")
with open(out, "w") as f:
    f.write("\n".join(sorted(imports)) + "\n\nfinal class MyView: NSView {}\n\n")
    f.write("\n\n".join(decls + funcs) + "\n")
print(f"README examples: {len(decls)} declarations, {len(funcs)} functions")
