#!/usr/bin/env python3
"""Issue or revoke one adaptive V2 client credential on the stats host."""
import getpass
import os
import sys

import redis
from adaptive_results import issue_client_token, revoke_client_token


def main():
    action = sys.argv[1] if len(sys.argv) == 2 else ""
    secret = os.environ.get("Z4R_ADAPTIVE_V2_INGEST_TOKEN", "")
    db = redis.Redis.from_url(os.environ.get("Z4R_STATS_REDIS", "redis://127.0.0.1:6379/0"))
    if action == "issue":
        print(issue_client_token(db, secret))
        return
    if action == "revoke":
        token = getpass.getpass("Client token to revoke: ")
        if not revoke_client_token(db, token, secret):
            raise SystemExit("No matching adaptive client token.")
        print("Adaptive client token revoked.")
        return
    raise SystemExit("Usage: adaptive_client_token.py issue|revoke")


if __name__ == "__main__":
    main()
