#!/usr/bin/env python3
"""Periodic materialization worker for adaptive V2 rankings."""
import os

import redis
from adaptive_results import refresh_browser_rankings, refresh_rankings


def main():
    db = redis.Redis.from_url(os.environ.get("Z4R_STATS_REDIS", "redis://127.0.0.1:6379/0"))
    print(f"adaptive V2 probe ranking groups published: {refresh_rankings(db)}")
    print(f"adaptive V2 browser ranking groups published: {refresh_browser_rankings(db)}")


if __name__ == "__main__":
    main()
