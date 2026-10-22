#!/usr/bin/env python3
"""Platform-independent smoke checks; not a substitute for an Xcode/device build."""
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
SWIFT_FILES=sorted((ROOT/'Sources').rglob('*.swift'))
errors=[]
if not SWIFT_FILES: errors.append('No Swift sources present')
for f in SWIFT_FILES:
    run=subprocess.run(['swiftc','-frontend','-parse',str(f)],capture_output=True,text=True)
    if run.returncode: errors.append('Swift parser '+str(f.relative_to(ROOT))+': '+run.stderr[:500])
print('Swift syntax parsed:',len(SWIFT_FILES),'files')
js_sources={}
for part in ('Sources/Engine/WebAssets.swift', 'Sources/Instagram/IGAssets.swift', 'Sources/Instagram/IGSessionAssets.swift'):
    source=(ROOT/part).read_text()
    for m in re.finditer(r'static let (\w+JS)\s*=\s*#"""\n(.*?)\n"""#',source,re.S):
        js_sources[part+'::'+m.group(1)]=m.group(2)
if not shutil.which('node'):
    errors.append('Node.js missing: could not syntax-check embedded JavaScript')
else:
    with tempfile.TemporaryDirectory() as tmp:
        for i,(name,js) in enumerate(js_sources.items()):
            path=Path(tmp)/f'asset_{i}.js'
            path.write_text(js)
            run=subprocess.run(['node','--check',str(path)],capture_output=True,text=True)
            if run.returncode:errors.append('JavaScript parse '+name+': '+run.stderr[:500])
print('Embedded JavaScript syntax checked:',len(js_sources),'blocks')
p=(ROOT/'Sources/Engine/PageBridge.swift').read_text()
s=(ROOT/'Sources/Instagram/IGSession.swift').read_text()
settings=(ROOT/'Sources/Instagram/IGSettings.swift').read_text()
creds=(ROOT/'Sources/Instagram/IGCredentials.swift').read_text()
models=(ROOT/'Sources/Instagram/IGModels.swift').read_text()
assertions={
    'Instagram navigation gated to authenticated page': 'if allowInstagramNavigation && LinkRules.isInstagram(url)' in p,
    'Dedicated session enables Instagram navigation': 'allowInstagramNavigation: true' in s,
    'No automatic sign-in before verification sheet display': 'await ensureSignedIn(timeout: 15)' not in s and 'await bridge.waitUntilReady(timeout: 15)' in s,
    'Loading failure offers Retry': 'Button("Retry")' in settings and 'loadError' in settings,
    'Log redacts p': '"p", "password"' in p and '<redacted>' in p,
    'Keychain update does not delete first': 'SecItemUpdate(selector as CFDictionary' in creds,
    'Keychain clears cookies on account switch': 'await WebFactory.shared.clearInstagramSession()' in creds,
    'Viewer URL checks hostname boundary': 'host == "insta-stories-viewer.com" || host.hasSuffix(".insta-stories-viewer.com")' in models,
}
for k,v in assertions.items():
    if not v: errors.append('Static regression check failed: '+k)
print('Static regression assertions:',sum(assertions.values()),'/',len(assertions))
if shutil.which('swiftc'):
    with tempfile.TemporaryDirectory() as tmp:
        run=subprocess.run(['swiftc',str(ROOT/'Sources/Engine/LinkRules.swift'),str(ROOT/'Sources/Model/Models.swift'),str(ROOT/'Sources/Instagram/IGModels.swift'),str(ROOT/'Tests/NavigationRulesSmoke.swift'),'-o',str(Path(tmp)/'smoke')],capture_output=True,text=True)
        if run.returncode: errors.append('Navigation smoke compile: '+run.stderr[:700])
        else:
            done=subprocess.run([str(Path(tmp)/'smoke')],capture_output=True,text=True)
            if done.returncode:errors.append('Navigation smoke run: '+done.stderr[:700])
            else:print(done.stdout.strip())
else:errors.append('Swift toolchain missing for smoke test')
if errors:
    for error in errors: print('FAIL:',error,file=sys.stderr)
    sys.exit(1)
print('PASS: all platform-independent smoke checks')
