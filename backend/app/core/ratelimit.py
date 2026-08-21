"""A small fixed-window rate limiter.

Deliberately in-process and dependency-free: adding Redis would buy exact
counting across instances at the cost of the "clone it and run it" self-hosting
story. With more than one instance the effective cap is per instance, so a
tenant may see up to (instances x limit) requests per minute. That is fine for
stopping abuse, and saying so is better than a shared-state claim we do not
actually make.
"""

import time

from fastapi import HTTPException

from app.core.config import settings

WINDOW_SECONDS = 60

# bucket key -> (window start, count in that window)
_counters: dict[str, tuple[float, int]] = {}


def reset_limits() -> None:
    """Drop all counters. Used by tests."""
    _counters.clear()


def check_rate_limit(bucket_key: str) -> None:
    """Raise 429 when this bucket has exceeded its allowance for the window."""
    limit = settings.RATE_LIMIT_PER_MINUTE
    if limit <= 0:
        return

    now = time.time()
    window_start = now - (now % WINDOW_SECONDS)

    start, count = _counters.get(bucket_key, (window_start, 0))
    if start != window_start:
        start, count = window_start, 0

    if count >= limit:
        retry_after = int(window_start + WINDOW_SECONDS - now) + 1
        raise HTTPException(
            status_code=429,
            detail="Too many requests. Try again shortly.",
            headers={"Retry-After": str(retry_after)},
        )

    _counters[bucket_key] = (start, count + 1)

    # Keep the dict from growing forever on a long-lived instance: anything
    # from an older window is dead weight.
    if len(_counters) > 10000:
        for key in [k for k, (s, _) in _counters.items() if s != window_start]:
            del _counters[key]
