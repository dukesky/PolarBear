import pathlib

import pytest


async def test_providers_reports_google_disabled_by_default(client):
    r = await client.get("/auth/providers")
    assert r.status_code == 200
    assert r.json() == {"google": False}


async def test_google_routes_absent_when_disabled(client):
    r = await client.get("/auth/google/authorize")
    assert r.status_code == 404


@pytest.mark.skip(
    reason="Exercising the OAuth association flow requires real Google OAuth "
    "credentials (GOOGLE_OAUTH_CLIENT_ID/SECRET) and a live provider round-trip, "
    "which isn't available in this test environment. Verified statically instead "
    "via test_associate_by_email_disabled_in_source below."
)
async def test_oauth_login_does_not_associate_by_email():
    """Would assert that logging in with Google for a pre-existing (unverified)
    email does NOT silently link to that account, i.e. associate_by_email=False."""


def test_associate_by_email_disabled_in_source():
    """Static guard for the associate_by_email=False fix in app/main.py.

    Regression check for the account-takeover finding: a Google OAuth login
    must not silently associate with a pre-registered, unverified email.
    """
    main_py = (
        pathlib.Path(__file__).resolve().parent.parent / "app" / "main.py"
    ).read_text()
    assert "associate_by_email=False" in main_py
    assert "associate_by_email=True" not in main_py
