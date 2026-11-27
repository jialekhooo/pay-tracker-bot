"""The public website: home, support, privacy and terms share one self-contained look, and their links work."""
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
        assert not re.search(r'<script|<link |<img |@import|url\(|src="', html), path
        assert html.count('<h1') == 1, path
        assert f'href="{path}" aria-current=page' in html, path
        for href in ('/', '/support', '/privacy', '/terms'):
            assert f'href="{href}"' in html, (path, href)
        for target in re.findall(r'href="#([^"]+)"', html):
            assert f'id="{target}"' in html, (path, target)


def test_support_answers_the_questions_app_review_and_people_ask():
    page = site.SUPPORT
    for text in (site.CONTACT, 'Restore purchases', 'Manage subscription', 'reportaproblem.apple.com', 'Delete account',
                 'Data &amp; backups', 'never send passwords'):
        assert text in page, text
    assert site.APP_STORE in site.HOME and 'up to 5 events' in site.HOME
