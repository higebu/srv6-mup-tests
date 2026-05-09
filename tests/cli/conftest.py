"""
Session + per-test fixtures for the BGP-MUP CLI property tests.

Helpers and constants live in `_helpers.py` so test modules can import
them directly via `from _helpers import ...` without going through
conftest.
"""

import pytest

from _helpers import (
    _baseline_mup_clean,
    setup_session,
    teardown_session,
)


@pytest.fixture(scope="session", autouse=True)
def frr_session():
    setup_session()
    yield
    teardown_session()


@pytest.fixture(autouse=True)
def baseline_per_test():
    """Restore a clean per-vrf MUP policy state after each test."""
    yield
    _baseline_mup_clean()
