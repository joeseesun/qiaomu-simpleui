"""Build the installable ZIP from tracked plugin source, never device settings."""
from pathlib import Path
import hashlib, json, zipfile
root=Path(__file__).resolve().parents[1]
plugin=root/'simpleui.koplugin'
output=root/'dist'
output.mkdir(exist_ok=True)
archive=output/'simpleui.koplugin.zip'
files=sorted(p for p in plugin.rglob('*') if p.is_file() and '__pycache__' not in p.parts)
assert (plugin/'main.lua') in files
assert (plugin/'features/library/sui_hidden_books.lua') in files
assert (plugin/'features/sui_qiaomu.lua') in files
with zipfile.ZipFile(archive,'w',zipfile.ZIP_DEFLATED) as z:
    for p in files:
        assert p.suffix not in {'.db','.sqlite','.session'},p
        z.write(p,p.relative_to(root))
with zipfile.ZipFile(archive) as z:
    assert z.testzip() is None
    assert all(n.startswith('simpleui.koplugin/') for n in z.namelist())
digest=hashlib.sha256(archive.read_bytes()).hexdigest()
(output/'SHA256SUMS').write_text(f'{digest}  {archive.name}\n')
print(json.dumps({'file':str(archive),'files':len(files),'bytes':archive.stat().st_size,'sha256':digest}))
