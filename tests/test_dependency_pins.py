"""pyproject.toml and requirements.txt pin the same versions.

Dependabot reads pyproject.toml as well. When it fell behind (FastAPI 0.115.0 and Python 3.10 there,
0.165.0 in requirements.txt), Dependabot proposed downgrading FastAPI.
"""
import tomllib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def test_pyproject_pins_match_requirements():
    project = tomllib.loads((ROOT / 'pyproject.toml').read_text())['project']
    pinned = sorted(project['dependencies'])
    required = sorted(line.strip() for line in (ROOT / 'requirements.txt').read_text().splitlines()
                      if line.strip() and not line.startswith('#'))
    assert pinned == required


def test_python_version_matches_docker_and_ci():
    project = tomllib.loads((ROOT / 'pyproject.toml').read_text())['project']
    assert project['requires-python'] == '>=3.12'
    for dockerfile in ('Dockerfile', 'howmuch_api/Dockerfile'):
        assert (ROOT / dockerfile).read_text().startswith('FROM python:3.12'), dockerfile
