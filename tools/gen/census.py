import json, re, subprocess, sys, tempfile, collections, yaml
spec, name = sys.argv[1], sys.argv[2]
d = yaml.safe_load(open(spec)) if spec.endswith(('.yaml','.yml')) else json.load(open(spec))
actions = []; n = 0
for path, ops in d['paths'].items():
    for m, op in ops.items():
        if m in ('get','post','put','patch','delete'):
            n += 1
            upd = {'x-moonbit-include': True}
            if not op.get('operationId'): upd['operationId'] = re.sub(r'[^A-Za-z0-9]+', '_', f"{m}_{path}").strip('_')
            actions.append({'target': f"$['paths'][{json.dumps(path)}][{json.dumps(m)}]", 'update': upd})
ov = tempfile.NamedTemporaryFile('w', suffix='.yaml', delete=False); yaml.safe_dump({'overlay':'1.0.0','info':{'title':'all','version':'0'},'actions':actions}, ov); ov.close()
r = subprocess.run(['.venv/bin/python','tools/gen/main.py','--spec',spec,'--overlay',ov.name,'--out','/tmp/claude-1000/-home-gaato/fc7c2250-3937-4c9d-9b52-7be55e5a0a85/scratchpad/census-out','--package','x/gen'], capture_output=True, text=True)
lines = [l for l in (r.stdout+r.stderr).splitlines() if l.startswith('/')]
kinds = collections.Counter()
for l in lines:
    msg = l.split(': ',1)[1].split(';')[0]
    msg = re.sub(r"\[.*?\]", "[...]", msg)
    kinds[msg] += 1
print(f"== {name}: operations={n} diagnostics={len(lines)} exit={r.returncode}")
for k, c in kinds.most_common(12): print(f"  {c:5d}  {k}")
