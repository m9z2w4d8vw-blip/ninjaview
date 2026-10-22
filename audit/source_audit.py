#!/usr/bin/env python3
"""Deterministic, exhaustive source-LINE inventory plus heuristic risk scan.

Scans every line of every tracked source/config file. This is a machine-aided
static inventory, *not* a proof that each line is correct or that iOS works.
Never ingests the user's private diagnostic log or app credentials.
"""
from __future__ import annotations
import csv
import json
import re
from collections import Counter, defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / 'audit'
INCLUDED_EXT = {'.swift', '.yml', '.plist', '.md', '.json'}
RULES = {
    'forced-cast': r'\bas!\b',
    'forced-try': r'\btry!\b',
    'forced-url-construction': r'URL\(string:.*\)!',
    'silent-optional-try': r'\btry\?\b',
    'webview': r'\bWKWebView\b',
    'java-script-bridge': r'callAsyncJavaScript|WKUserScript|evaluateJavaScript|window\.__',
    'keychain': r'SecItem|kSec',
    'persistent-settings': r'UserDefaults|@AppStorage',
    'network': r'URLSession|URLRequest|fetch\(|XMLHttpRequest|http(s)?://',
    'task-or-timing': r'\bTask\b|Task\.sleep|async\b|await\b',
    'filesystem': r'FileManager|fileExists|createDirectory|moveItem|copyItem|removeItem',
    'log-or-sensitive': r'DebugLog|password|cookie|token|secret',
    'navigation-or-domain': r'(\.host\b|navigationAction|decidePolicy|\.hasSuffix|\.contains\("instagram)',
    'force-fatal': r'fatalError\(|preconditionFailure\(',
    'deferred-cleanup': r'\bdefer\s*\{',
    'try-catch': r'\bcatch\b',
    'potential-unbounded-loop': r'\bwhile\s+(true|\S+\s*<)',
}


def code_kind(line: str, in_multiline: bool) -> tuple[str, bool]:
    stripped = line.strip()
    if not stripped: return 'blank', in_multiline
    if in_multiline:
        if '*/' in stripped: return 'comment', False
        return 'comment', True
    if stripped.startswith('//') or stripped.startswith('*'): return 'comment', False
    if stripped.startswith('/*'): return 'comment', '*/' not in stripped
    return 'code', False


def main():
    file_records = []
    row_count = Counter()
    risk_totals = Counter()
    rows = []
    roots = ['Sources', 'Config', 'Resources', '.github', 'project.yml', 'README.md']
    selected = set()
    for root in roots:
        rp = ROOT / root
        candidates = [rp] if rp.is_file() else (rp.rglob('*') if rp.exists() else [])
        for f in candidates:
            if f.is_file() and f.suffix.lower() in INCLUDED_EXT:
                selected.add(f)
    for path in sorted(selected):
        rel = path.relative_to(ROOT).as_posix()
        raw = path.read_text(encoding='utf-8')
        lines = raw.splitlines()
        kind_counter = Counter()
        file_risks = Counter()
        multiline = False
        for number, content in enumerate(lines, 1):
            kind, multiline = code_kind(content, multiline)
            kind_counter[kind] += 1
            matches = [tag for tag, pattern in RULES.items() if re.search(pattern, content)] if kind == 'code' else []
            for tag in matches: file_risks[tag] += 1; risk_totals[tag] += 1
            # One entry for every physical source line; not only flagged lines.
            rows.append({'file':rel,'line':number,'kind':kind,'heuristic_flags':';'.join(matches),'source':content})
            row_count[kind] += 1
        file_records.append({'path':rel,'lines':len(lines),'classification':dict(kind_counter),
                             'risk_flags':dict(file_risks)})
    with (OUTPUT/'line-index.tsv').open('w',newline='',encoding='utf-8') as fp:
        writer=csv.DictWriter(fp,fieldnames=('file','line','kind','heuristic_flags','source'),delimiter='\t')
        writer.writeheader();writer.writerows(rows)
    summary={'description':'Automatic every-line static source inventory: not a semantic correctness guarantee',
             'files':len(file_records),'lines_total':len(rows),'line_kinds':dict(row_count),
             'flag_occurrences':dict(risk_totals),'files_detail':file_records}
    (OUTPUT/'source-summary.json').write_text(json.dumps(summary,indent=2,ensure_ascii=False)+'\n',encoding='utf-8')
    print('Indexed',len(rows),'source/config/documentation lines in',len(file_records),'files')
    print('Kinds:',dict(row_count),' Flags:',dict(risk_totals))

if __name__=='__main__': main()
