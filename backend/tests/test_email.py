def test_send_email_without_smtp_configured_returns_false(monkeypatch, capsys):
    from app.core.config import settings
    from app.services import email

    monkeypatch.setattr(settings, "SMTP_HOST", "")
    assert email.send_email("a@b.com", "Subject", "Body") is False
    assert "a@b.com" in capsys.readouterr().out


def test_password_reset_logs_the_link_when_unconfigured(monkeypatch, capsys):
    from app.core.config import settings
    from app.services import email

    monkeypatch.setattr(settings, "SMTP_HOST", "")
    monkeypatch.setattr(settings, "FRONTEND_URL", "https://app.example.com")

    assert email.send_password_reset("merchant@shop.com", "tok123") is False
    printed = capsys.readouterr().out
    assert "https://app.example.com/reset-password?token=tok123" in printed


def test_send_email_uses_smtp_when_configured(monkeypatch):
    from app.core.config import settings
    from app.services import email

    sent = {}

    class FakeSMTP:
        def __init__(self, host, port, timeout=None):
            sent["host"] = host
            sent["port"] = port

        def __enter__(self):
            return self

        def __exit__(self, *a):
            return False

        def starttls(self):
            sent["tls"] = True

        def login(self, user, password):
            sent["login"] = user

        def send_message(self, msg):
            sent["to"] = msg["To"]
            sent["subject"] = msg["Subject"]

    monkeypatch.setattr(settings, "SMTP_HOST", "smtp.example.com")
    monkeypatch.setattr(settings, "SMTP_PORT", 587)
    monkeypatch.setattr(settings, "SMTP_USER", "user")
    monkeypatch.setattr(settings, "SMTP_PASSWORD", "pass")
    monkeypatch.setattr(settings, "SMTP_TLS", True)
    monkeypatch.setattr(email.smtplib, "SMTP", FakeSMTP)

    assert email.send_email("to@shop.com", "Hi", "Body") is True
    assert sent["host"] == "smtp.example.com"
    assert sent["tls"] is True
    assert sent["login"] == "user"
    assert sent["to"] == "to@shop.com"


def test_send_email_swallows_transport_errors(monkeypatch):
    from app.core.config import settings
    from app.services import email

    def boom(*a, **k):
        raise OSError("connection refused")

    monkeypatch.setattr(settings, "SMTP_HOST", "smtp.example.com")
    monkeypatch.setattr(email.smtplib, "SMTP", boom)

    assert email.send_email("to@shop.com", "Hi", "Body") is False
