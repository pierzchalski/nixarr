"""
Bazarr post-processing command: ask Sonarr or Radarr to rescan the series or
movie Bazarr just wrote a subtitle for, so the new sidecar becomes one of its
tracked extra files.

Bazarr runs this inside the download and waits for it, ignores the exit code,
logs stdout at INFO and any stderr at ERROR. So it makes one short request,
prints one line, and never raises.
"""

import argparse
import json
import sys
import urllib.error
import urllib.request

TIMEOUT_SECONDS = 10


def parse_id(value: str) -> int | None:
    # Bazarr passes "" for a movie's series id, and "None" for one uploaded
    # through the UI.
    try:
        parsed = int(value)
    except ValueError:
        return None
    return parsed if parsed > 0 else None


def read_key(path: str) -> str:
    with open(path, "r", encoding="utf-8") as f:
        return f.read().strip()


def arr_url(arr: dict) -> str:
    # The same connection settings Bazarr itself uses for this Sonarr/Radarr.
    scheme = "https" if arr["ssl"] else "http"
    base = arr["base_url"].strip("/")
    return f"{scheme}://{arr['ip']}:{arr['port']}" + (f"/{base}" if base else "")


def queue_command(arr: dict, body: dict) -> dict:
    request = urllib.request.Request(
        f"{arr_url(arr)}/api/v3/command",
        data=json.dumps(body).encode("utf-8"),
        method="POST",
        headers={
            "X-Api-Key": read_key(arr["api_key_file"]),
            "Content-Type": "application/json",
        },
    )
    with urllib.request.urlopen(request, timeout=TIMEOUT_SECONDS) as response:
        return json.loads(response.read() or b"{}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config-file", required=True)
    parser.add_argument("--series-id", default="")
    parser.add_argument("--episode-id", default="")
    args = parser.parse_args()

    with open(args.config_file, "r", encoding="utf-8") as f:
        config = json.load(f)

    series_id = parse_id(args.series_id)
    if series_id is not None:
        name, arr, body = (
            "Sonarr",
            config.get("sonarr"),
            {
                "name": "RescanSeries",
                "seriesId": series_id,
            },
        )
    else:
        # For a movie Bazarr puts the Radarr id in {{episode_id}}.
        movie_id = parse_id(args.episode_id)
        if movie_id is None:
            print(
                f"No series or movie id (series {args.series_id!r}, "
                f"episode {args.episode_id!r}); nothing to rescan"
            )
            return 0
        name, arr, body = (
            "Radarr",
            config.get("radarr"),
            {
                "name": "RescanMovie",
                "movieId": movie_id,
            },
        )

    if arr is None:
        print(f"{name} is not configured here; not asking it to rescan")
        return 0

    try:
        command = queue_command(arr, body)
    except (OSError, urllib.error.URLError, ValueError) as e:
        detail = e.read()[:300] if isinstance(e, urllib.error.HTTPError) else ""
        print(f"{name} {body['name']} request failed: {e} {detail!r}", file=sys.stderr)
        return 1

    target = series_id if series_id is not None else movie_id
    print(
        f"{name} {body['name']} {target}: command {command.get('id')}, "
        f"status {command.get('status')}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
