#!/usr/bin/env python3
"""Smoke test a running HowMuch API and website: the few things that must work after every deploy.

    python3 scripts/smoke.py https://howmuch.jialekhoo.com https://howmuch-ios.fly.dev
    python3 scripts/smoke.py https://howmuch-ios-staging.fly.dev --api-only

Standard library only, so it runs anywhere (CI, a laptop, the uptime check). Exits 1 on any failure.
"""
from __future__ import annotations

import json
import sys
import time
import urllib.error
import urllib.request


def fetch(url: str, timeout: float = 15) -> tuple[int, dict, str, float]:
    request = urllib.request.Request(url, headers={'User-Agent': 'HowMuch smoke test'})
    start = time.monotonic()
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return response.status, dict(response.headers), response.read().decode('utf-8', 'replace'), time.monotonic() - start
    except urllib.error.HTTPError as error:
        return error.code, dict(error.headers), error.read().decode('utf-8', 'replace'), time.monotonic() - start


def check_api(base: str) -> list[str]:
    problems = []
    status, _, body, seconds = fetch(base + '/healthz')
    if status != 200 or json.loads(body or '{}').get('status') != 'ok':
        problems.append(f'{base}/healthz answered {status}: {body[:200]}')
    elif seconds > 3:
        problems.append(f'{base}/healthz took {seconds:.1f}s')
    # Signed-in routes must refuse a caller with no session.
    status, _, _, _ = fetch(base + '/v1/auth/me')
    if status != 401:
        problems.append(f'{base}/v1/auth/me without a session answered {status}, expected 401')
    status, _, _, _ = fetch(base + '/openapi.json')
    if status != 404:
        problems.append(f'{base}/openapi.json is public ({status})')
    return problems


def check_site(base: str) -> list[str]:
    problems = []
    for path, needle in (('/', 'HowMuch'), ('/support', 'FAQPage'), ('/privacy', 'Privacy'), ('/robots.txt', 'Sitemap:'),
                         ('/sitemap.xml', '<urlset'), ('/llms.txt', '# HowMuch')):
        status, _, body, seconds = fetch(base + path)
        if status != 200 or needle not in body:
            problems.append(f'{base}{path} answered {status} without "{needle}"')
        elif seconds > 5:
            problems.append(f'{base}{path} took {seconds:.1f}s')
    status, headers, body, _ = fetch(base + '/no-such-page-smoke-test')
    if status != 404 or 'Page not found' not in body:
        problems.append(f'{base}/no-such-page answered {status} without the 404 page')
    return problems


def main(argv: list[str]) -> int:
    api_only = '--api-only' in argv
    urls = [a.rstrip('/') for a in argv if not a.startswith('--')]
    if not urls:
        print(__doc__)
        return 2
    problems = []
    for index, base in enumerate(urls):
        problems += check_api(base)
        if index == 0 and not api_only:
            problems += check_site(base)
    for problem in problems:
        print('FAIL', problem)
    print('OK' if not problems else f'{len(problems)} problem(s)')
    return 1 if problems else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
