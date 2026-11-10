"""The public privacy policy: a readable page that keeps the statements stores and Google check for."""
import re

from howmuch_api import privacy


def test_policy_keeps_the_required_statements():
    page = privacy.PAGE
    for text in ('Google API Services User Data Policy', 'Limited Use requirements', 'not used to train AI models',
                 'Delete account', 'advertising or analytics', 'Friends never see your shifts',
                 privacy.CONTACT, privacy.UPDATED):
        assert text in page, text


def test_page_is_self_contained_and_its_links_work():
    page = privacy.PAGE
    assert not re.search(r'<script|<link |<img |@import|url\(', page)
    assert re.findall(r'src="', page) == []
    targets = re.findall(r'href="#([^"]+)"', page)
    assert len(targets) == 10
    for target in targets:
        assert f'id="{target}"' in page, target


def test_every_table_row_has_cells_for_each_heading():
    for table in re.findall(r'<table>.*?</table>', privacy.PAGE, re.S):
        headings = len(re.findall(r'<th ', table))
        rows = re.findall(r'<tr>(.*?)</tr>', table.split('<tbody>')[1], re.S)
        assert rows and all(len(re.findall(r'<td>', row)) == headings for row in rows)
