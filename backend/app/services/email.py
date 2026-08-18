"""Outbound email over plain SMTP.

No third-party service and no extra dependency: a self-hosted install points
this at its own mail server, and an install with nothing configured still
works because reset links are written to the log for an operator to relay.
"""

import smtplib
from email.message import EmailMessage

from app.core.config import settings


def send_email(to: str, subject: str, body: str) -> bool:
    """Returns True only when the message actually went out over SMTP."""
    if not settings.SMTP_HOST:
        print(f"[email] SMTP not configured - message for {to} not sent:\n{body}")
        return False

    message = EmailMessage()
    message["From"] = settings.SMTP_FROM
    message["To"] = to
    message["Subject"] = subject
    message.set_content(body)

    try:
        with smtplib.SMTP(settings.SMTP_HOST, settings.SMTP_PORT, timeout=10) as smtp:
            if settings.SMTP_TLS:
                smtp.starttls()
            if settings.SMTP_USER:
                smtp.login(settings.SMTP_USER, settings.SMTP_PASSWORD)
            smtp.send_message(message)
        return True
    except Exception as e:
        # A broken mailer must never break the request that triggered it.
        print(f"[email] failed to send to {to}: {e}")
        return False


def send_password_reset(to: str, token: str) -> bool:
    link = f"{settings.FRONTEND_URL}/reset-password?token={token}"
    body = (
        "Someone asked to reset the password for your PolarBear account.\n\n"
        f"Open this link to choose a new password:\n{link}\n\n"
        "The link expires in one hour. If this wasn't you, ignore this email - "
        "nothing has changed."
    )
    return send_email(to, "Reset your PolarBear password", body)
