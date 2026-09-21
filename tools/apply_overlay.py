# /// script
# requires-python = ">=3.11"
# dependencies = ["jsonpath-rfc9535>=0.1", "pyyaml>=6"]
# ///
"""Apply OpenAPI Overlay 1.x documents in order. Fails on zero-match and no-op actions."""
import copy, json, sys
import yaml
from jsonpath_rfc9535 import JSONPathEnvironment

ENV = JSONPathEnvironment()

def load(path):
    with open(path, encoding="utf-8") as f:
        return yaml.safe_load(f) if path.endswith((".yaml", ".yml")) else json.load(f)

def merge(target, update):
    if isinstance(target, dict) and isinstance(update, dict):
        for k, v in update.items():
            target[k] = merge(target[k], v) if k in target else copy.deepcopy(v)
        return target
    if isinstance(target, list) and isinstance(update, list):
        target.extend(copy.deepcopy(update)); return target
    return copy.deepcopy(update)

def apply(doc, overlay, name):
    problems = []
    for i, action in enumerate(overlay["actions"]):
        label = f"{name}#{i} {action['target']}"
        nodes = ENV.find(action["target"], doc)
        if len(nodes) == 0 and not action.get("x-allow-zero-match"):
            problems.append(f"zero-match: {label}"); continue
        before = json.dumps(doc, sort_keys=True)
        for node in reversed(list(nodes)):
            parent = doc
            for part in node.location[:-1]:
                parent = parent[part]
            key = node.location[-1] if node.location else None
            if action.get("remove"):
                del parent[key]
            elif "update" in action:
                if key is None: merge(doc, action["update"])
                else: parent[key] = merge(parent[key], action["update"])
        if json.dumps(doc, sort_keys=True) == before:
            problems.append(f"no-op (upstream already fixed?): {label}")
    return problems

if __name__ == "__main__":
    spec, out, *overlays = sys.argv[1:]
    doc = load(spec); problems = []
    for path in overlays:
        problems += apply(doc, load(path), path)
    with open(out, "w", encoding="utf-8") as f:
        json.dump(doc, f, ensure_ascii=False, indent=1)
    for p in problems: print("overlay problem:", p, file=sys.stderr)
    sys.exit(1 if problems else 0)
