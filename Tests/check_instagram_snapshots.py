"""Offline Instagram DOM smoke test using locally saved SingleFile HTML.

Usage:
  python -m pip install playwright lxml
  python -m playwright install chromium
  python Tests/check_instagram_snapshots.py '/path/to/Instagram*.html'

No real Instagram requests, accounts or credentials are used. User HTML files are not
included in the source release (they can contain private content).
"""
import glob
import json
import sys
import os
import shutil
from pathlib import Path
from lxml import html
from playwright.sync_api import sync_playwright


def clean_html(filename):
    tree = html.fromstring(Path(filename).read_text(encoding='utf-8'))
    for el in tree.xpath('//style|//script|//link|//img|//video|//source'):
        if el.tag in ('img', 'video', 'source'):
            for attr in ('src', 'srcset', 'poster'):
                el.attrib.pop(attr, None)
        else:
            el.drop_tree()
    return html.tostring(tree, encoding='unicode')


def main(pattern):
    files = sorted(glob.glob(pattern))
    if not files:
        raise SystemExit('No snapshots matched the pattern.')
    swift = Path(__file__).resolve().parents[1] / 'Sources/Instagram/IGSessionAssets.swift'
    text = swift.read_text()
    script = text.split('#"""', 1)[1].split('"""#', 1)[0]
    tested = 0
    with sync_playwright() as playwright:
        executable = os.environ.get('IG_CHROMIUM_PATH') or shutil.which('chromium') or shutil.which('google-chrome')
        browser = playwright.chromium.launch(headless=True, executable_path=executable)
        page = browser.new_page()
        page.route('**/*', lambda route: route.abort())
        for filename in files:
            page.goto('about:blank')
            page.set_content(clean_html(filename), wait_until='domcontentloaded')
            page.evaluate(script)
            state = page.evaluate('window.__igl.probe()')
            expected_comments = page.locator('a[href*="/c/"] time').count()
            assert state['comments'] == expected_comments, (filename, state, expected_comments)
            print(Path(filename).name, json.dumps(state))
            tested += 1
        browser.close()
    print(f'PASS: {tested} offline Instagram snapshots')


if __name__ == '__main__':
    if len(sys.argv) != 2:
        raise SystemExit('Usage: python Tests/check_instagram_snapshots.py "Instagram*.html"')
    main(sys.argv[1])
