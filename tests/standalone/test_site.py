"""The public website: home, support, privacy and terms share one self-contained look, and their links work."""
import json
import re

from fastapi.testclient import TestClient

from howmuch_api import privacy, site
from howmuch_api.main import app

PAGES = {'/': site.HOME, '/support': site.SUPPORT, '/privacy': privacy.PAGE}


def test_pages_are_served_as_html_and_terms_go_to_apples_licence():
    client = TestClient(app)  # no lifespan: these pages don't touch the database
    for path, html in PAGES.items():
        response = client.get(path)
        assert response.status_code == 200 and response.headers['content-type'].startswith('text/html'), path
        assert response.text == html
    terms = client.get('/terms', follow_redirects=False)
    assert terms.status_code == 307 and terms.headers['location'] == site.TERMS


def test_every_page_is_self_contained_and_links_to_the_others():
    for path, html in PAGES.items():
        # The only scripts are JSON-LD on home (the app) and support (the FAQ): data for search engines, not code.
        code = re.sub(r'<script type="application/ld\+json">.*?</script>', '', html, flags=re.S)
        assert not re.search(r'<script|@import|url\(', code), path
        assert (code != html) == (path in ('/', '/support')), path
        # The only links are to HowMuch's own icons and the page's canonical address.
        assert re.findall(r'<link [^>]*>', html) and all(
            re.search(r'href="/(favicon\.ico|favicon\.svg|apple-touch-icon\.png)"', tag) or tag == f'<link rel="canonical" href="{site.SITE}{path}">'
            for tag in re.findall(r'<link [^>]*>', html)), path
        # The only images are the home page's own screenshots, served by HowMuch.
        assert all(src.startswith('/screens/') for src in re.findall(r'src="([^"]+)"', html)), path
        assert html.count('<h1') == 1, path
        # Every page, home included, shows the support address in the footer, and no other address.
        assert f'href="mailto:{site.CONTACT}?subject=HowMuch%20support">{site.CONTACT}</a>' in html, path
        assert set(re.findall(r'[\w.+-]+@[\w-]+\.[\w.]+', html)) == {site.CONTACT}, path
        assert f'href="{path}" aria-current=page' in html, path
        for href in ('/', '/support', '/privacy', '/terms'):
            assert f'href="{href}"' in html, (path, href)
        for target in re.findall(r'href="#([^"]+)"', html):
            assert f'id="{target}"' in html, (path, target)


def test_support_answers_the_questions_app_review_and_people_ask():
    page = site.SUPPORT
    for text in (site.CONTACT, 'https://t.me/jialekhoo', '@jialekhoo', 'Restore purchases', 'Manage subscription', 'reportaproblem.apple.com', 'Delete account',
                 'Data &amp; backups', 'never send passwords'):
        assert text in page, text
    assert site.APP_STORE in site.HOME and 'up to 5 events' in site.HOME


def test_home_page_screenshots_are_served_and_described():
    client = TestClient(app)
    images = re.findall(r'<img src="(/screens/[^"]+)"[^>]*alt="([^"]+)"', site.HOME)
    assert len(images) == len(site.SCREENS) == 5
    for src, alt in images:
        response = client.get(src)
        assert response.status_code == 200 and response.headers['content-type'] == 'image/jpeg', src
        assert response.content[:3] == b'\xff\xd8\xff' and alt, src
    assert client.get('/screens/nope.jpg').status_code == 404
    assert client.get('/screens/..%2Fmain.jpg').status_code == 404


def test_the_browser_tab_and_home_screen_show_penny():
    client = TestClient(app)
    svg = client.get('/favicon.svg')
    assert svg.status_code == 200 and svg.headers['content-type'].startswith('image/svg+xml') and svg.text.startswith('<svg')
    for path in ('/favicon.ico', '/apple-touch-icon.png'):
        response = client.get(path)
        assert response.status_code == 200 and response.headers['content-type'] == 'image/png', path
        assert response.content[:8] == b'\x89PNG\r\n\x1a\n', path


def test_search_engines_and_link_previews_find_every_page():
    client = TestClient(app)
    for path, html in PAGES.items():
        assert f'<link rel="canonical" href="{site.SITE}{path}">' in html, path
        assert f'<meta property="og:url" content="{site.SITE}{path}">' in html, path
        assert f'<meta property="og:image" content="{site.SITE}/og-image.png">' in html, path
        assert html.count('<meta name="description"') == 1, path
    data = json.loads(re.search(r'<script type="application/ld\+json">(.*?)</script>', site.HOME, re.S).group(1))
    app_data = next(item for item in data['@graph'] if item['@type'] == 'MobileApplication')
    assert app_data['installUrl'] == site.APP_STORE and app_data['operatingSystem'] == 'iOS' and 'aggregateRating' not in app_data
    robots = client.get('/robots.txt')
    assert robots.status_code == 200 and f'Sitemap: {site.SITE}/sitemap.xml' in robots.text and 'Disallow: /\n' not in robots.text
    sitemap = client.get('/sitemap.xml')
    assert sitemap.status_code == 200 and sitemap.headers['content-type'].startswith('application/xml')
    assert re.findall(r'<loc>([^<]+)</loc>', sitemap.text) == [f'{site.SITE}{path}' for path in PAGES]
    image = client.get('/og-image.png')
    assert image.status_code == 200 and image.content[:8] == b'\x89PNG\r\n\x1a\n'
    assert int.from_bytes(image.content[16:20], 'big') == 1200 and int.from_bytes(image.content[20:24], 'big') == 630


def test_old_fly_dev_pages_move_to_the_site_but_the_api_stays():
    client = TestClient(app, base_url=f'https://{site.LEGACY_HOST}')
    for path in PAGES:
        moved = client.get(path, follow_redirects=False)
        assert moved.status_code == 301 and moved.headers['location'] == f'{site.SITE}{path}', path
    assert client.get('/support?ref=app', follow_redirects=False).headers['location'] == f'{site.SITE}/support?ref=app'
    assert client.get('/healthz').status_code == 200
    assert client.get('/robots.txt').status_code == 200
    here = TestClient(app, base_url=site.SITE)
    for path, html in PAGES.items():
        assert here.get(path).text == html, path
