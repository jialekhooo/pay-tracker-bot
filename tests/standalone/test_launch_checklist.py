"""Production basics: real error pages, no public API schema, health, rate limits, logging and diagnostics."""
import json
import re

from fastapi import APIRouter
from fastapi.testclient import TestClient

from howmuch_api import diagnostics, main, site
from howmuch_api.main import app


def test_missing_pages_get_the_sites_404_page_but_the_api_keeps_json():
    client = TestClient(app)
    page = client.get('/no-such-page')
    assert page.status_code == 404 and page.headers['content-type'].startswith('text/html')
    assert page.text == site.NOT_FOUND and 'Page not found' in page.text
    # Error pages are not indexed and have no canonical address.
    assert '<meta name="robots" content="noindex">' in page.text and 'rel="canonical"' not in page.text
    api = client.get('/v1/no-such-route')
    assert api.status_code == 404 and api.json() == {'detail': 'Not Found'}


def test_the_api_schema_and_docs_are_not_public():
    client = TestClient(app)
    for path in ('/openapi.json', '/docs', '/redoc'):
        assert client.get(path).status_code == 404, path


def test_support_faq_data_matches_the_questions_on_the_page():
    data = json.loads(re.search(r'<script type="application/ld\+json">(.*?)</script>', site.SUPPORT, re.S).group(1).replace('<\\/', '</'))
    assert data['@type'] == 'FAQPage'
    questions = [q['name'] for q in data['mainEntity']]
    assert len(questions) == site.SUPPORT_BODY.count('<details>') and 'How do I delete my account?' in questions
    assert all(q['acceptedAnswer']['text'] and '<' not in q['acceptedAnswer']['text'] for q in data['mainEntity'])


def test_answer_engines_and_crawlers_get_plain_text_guides():
    client = TestClient(app)
    llms = client.get('/llms.txt')
    assert llms.status_code == 200 and llms.text.startswith('# HowMuch') and f'{site.SITE}/support' in llms.text
    robots = client.get('/robots.txt').text
    assert 'Disallow: /v1/' in robots and f'Sitemap: {site.SITE}/sitemap.xml' in robots


def test_health_check_reads_the_database(tmp_path, monkeypatch):
    monkeypatch.setenv('HOWMUCH_DB', str(tmp_path / 'h.sqlite3'))
    class Unreadable:
        def execute(self, *args):
            raise OSError('disk gone')

    with TestClient(app) as client:
        assert client.get('/healthz').json()['status'] == 'ok'
        storage = app.state.storage
        working, storage._conn = storage._conn, Unreadable()  # the database stops answering
        try:
            broken = client.get('/healthz')
        finally:
            storage._conn = working
        assert broken.status_code == 503 and broken.json()['database'] == 'unavailable'


def test_unhandled_errors_are_recorded_and_answered_with_the_right_page(tmp_path, monkeypatch):
    monkeypatch.setenv('HOWMUCH_DB', str(tmp_path / 'e.sqlite3'))
    boom = APIRouter()

    @boom.get('/test-boom/{token}')
    async def api_boom(token: str):
        raise RuntimeError('kaboom')

    @boom.get('/test-boom-page')
    async def page_boom():
        raise RuntimeError('kaboom')

    pages = APIRouter()
    pages.add_api_route('/test-boom-page', page_boom, methods=['GET'])
    boom.routes[:] = [r for r in boom.routes if r.path != '/test-boom-page']
    app.include_router(boom, prefix='/v1')  # like the real API routers
    app.include_router(pages)
    try:
        with TestClient(app, raise_server_exceptions=False) as client:
            api = client.get('/v1/test-boom/secret-token-123')
            assert api.status_code == 500 and 'Something went wrong' in api.json()['detail']
            page = client.get('/test-boom-page')
            assert page.status_code == 500 and page.text == site.SERVER_ERROR
            rows = app.state.storage._conn.execute('SELECT source,kind,summary,detail FROM diagnostics').fetchall()
            # The route template is kept, never the raw URL with its token.
            assert [(r[0], r[1], r[2]) for r in rows] == [('server', 'RuntimeError', 'GET /v1/test-boom/{token}'),
                                                         ('server', 'RuntimeError', 'GET /test-boom-page')]
            assert 'secret-token-123' not in ''.join(r[3] + r[2] for r in rows) and 'kaboom' in rows[0][3]
    finally:
        app.router.routes[:] = [r for r in app.router.routes if 'test-boom' not in getattr(r, 'path', '')]


def test_app_crash_reports_are_stored_without_an_account_and_summarised(tmp_path, monkeypatch):
    monkeypatch.setenv('HOWMUCH_DB', str(tmp_path / 'd.sqlite3'))
    with TestClient(app) as client:
        report = {'version': '1.5 (90)', 'device': 'iPhone17,3', 'items': [
            {'kind': 'crash', 'summary': 'EXC_BAD_ACCESS (SIGSEGV)', 'detail': 'HowMuch +0x1234'},
            {'kind': 'crash', 'summary': 'EXC_BAD_ACCESS (SIGSEGV)', 'detail': 'HowMuch +0x1234'},
            {'kind': 'hang', 'summary': 'Main thread hung 2.1 s'},
            {'kind': 'not-a-kind', 'summary': 'ignored'}]}
        assert client.post('/v1/diagnostics', json=report).json() == {'saved': 3}
        assert client.post('/v1/diagnostics', content=b'not json').status_code == 400
        assert client.post('/v1/diagnostics', content=b'x' * (diagnostics.MAX_BODY + 1)).status_code == 413
        text = diagnostics.summary(app.state.storage._conn)
        assert '3 reports' in text and '2 × app    crash' in text and 'Main thread hung' in text


def test_every_caller_has_a_site_wide_request_limit(monkeypatch):
    monkeypatch.setattr(main, 'GLOBAL_LIMIT', 5)
    main._recent.clear()
    client = TestClient(app)
    codes = [client.get('/robots.txt').status_code for _ in range(7)]
    assert codes[:5] == [200] * 5 and codes[5:] == [429, 429]
    assert client.get('/healthz').status_code != 429  # uptime checks are never limited
    main._recent.clear()
