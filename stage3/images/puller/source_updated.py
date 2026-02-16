#!/usr/bin/env python3
"""
Check if we can skip syncing a Docker image based on:
1. Whether we synced it recently (within SKIP_IF_SYNCED_HOURS, default 8h)
2. For Docker Hub images: whether the tag was pushed since our last sync
   (uses Docker Hub REST API at hub.docker.com, NOT the Registry distribution
    API at registry-1.docker.io, so it does NOT count toward pull rate limits)

Exit codes:
  0 - Safe to skip (source not updated since our last sync)
  1 - Should proceed with sync (source updated or can't determine)
  2 - Invalid arguments
"""
import sys
import os
import time
import requests
from datetime import datetime, timezone

DOCKERHUB_API = "https://hub.docker.com/v2/repositories"


def is_dockerhub_image(image_str):
    """Check if the image is from Docker Hub (not ghcr.io, mcr.microsoft.com, etc.)."""
    from_registry = os.environ.get('FROM_REGISTRY', '')
    if from_registry:
        return False

    repo_part = image_str.split(':')[0]
    parts = repo_part.split('/')
    if len(parts) == 1:
        return True   # Official image like "nginx"
    if len(parts) == 2 and '.' not in parts[0]:
        return True   # User image like "grafana/grafana"
    return False


def parse_dockerhub_image(image_str):
    """Parse a Docker Hub image string into (namespace, repo, tag)."""
    if ':' in image_str:
        repo_part, tag = image_str.rsplit(':', 1)
    else:
        repo_part = image_str
        tag = "latest"

    parts = repo_part.split('/')
    if len(parts) == 1:
        return "library", parts[0], tag
    else:
        return parts[0], parts[1], tag


def get_dockerhub_tag_last_pushed(namespace, repo, tag):
    """
    Query Docker Hub REST API for the tag's last_pushed timestamp.
    Returns epoch float or None on failure.
    """
    url = f"{DOCKERHUB_API}/{namespace}/{repo}/tags/{tag}/"
    try:
        resp = requests.get(url, timeout=15)
        if resp.status_code != 200:
            return None
        data = resp.json()
        last_pushed = data.get('tag_last_pushed') or data.get('last_updated')
        if not last_pushed:
            return None
        # Parse ISO 8601 timestamp (e.g. "2024-01-15T10:30:00.123456Z")
        last_pushed = last_pushed.rstrip('Z').split('+')[0]
        if '.' in last_pushed:
            dt = datetime.strptime(last_pushed, "%Y-%m-%dT%H:%M:%S.%f")
        else:
            dt = datetime.strptime(last_pushed, "%Y-%m-%dT%H:%M:%S")
        dt = dt.replace(tzinfo=timezone.utc)
        return dt.timestamp()
    except Exception:
        return None


def main():
    if len(sys.argv) != 3:
        print("Usage: source_updated.py <image> <last_sync_epoch>", file=sys.stderr)
        sys.exit(2)

    image = sys.argv[1]
    try:
        last_sync_epoch = float(sys.argv[2])
    except ValueError:
        sys.exit(2)

    # --- Layer 1: time-based skip (works for ALL registries, zero API calls) ---
    skip_hours = float(os.environ.get('SKIP_IF_SYNCED_HOURS', '8'))
    hours_since_sync = (time.time() - last_sync_epoch) / 3600.0

    if hours_since_sync < skip_hours:
        # Synced recently enough – safe to skip
        sys.exit(0)

    # --- Layer 2: Docker Hub REST API check (lightweight, separate rate limit) ---
    if is_dockerhub_image(image):
        namespace, repo, tag = parse_dockerhub_image(image)
        tag_last_pushed = get_dockerhub_tag_last_pushed(namespace, repo, tag)
        if tag_last_pushed is not None and tag_last_pushed <= last_sync_epoch:
            # Tag has NOT been pushed since our last successful sync
            sys.exit(0)

    # Cannot determine or image was updated – proceed with sync
    sys.exit(1)


if __name__ == '__main__':
    main()
