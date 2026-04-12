"""
Standalone test script for the Clicky MolmoWeb grounding endpoint.

Sidesteps all shell escaping / variable substitution headaches — just run:

    python modal/test_ground.py

What it does:
    1. Pings /health to confirm the Modal container is reachable.
    2. Sends a tiny 1x1 PNG to /ground — fastest way to verify the base64
       transport and PIL decoding work end-to-end. If this fails, the
       problem is in the request/response pipeline, not your screenshot.
    3. Sends /Users/deepeshbansal/clicky_loom/test.png to /ground with a
       real grounding prompt. This is the "does MolmoWeb actually do what
       we want?" test.

Prints everything clearly so you can copy-paste back if anything fails.

Requirements: just the Python stdlib (urllib). No `requests` dep, no
venv juggling — this script can run with any Python 3 you've got.
"""

import base64
import json
import os
import sys
import time
from pathlib import Path
from urllib import request as urllib_request
from urllib.error import HTTPError, URLError


# -------------------------------------------------------------------
# CONFIGURATION — edit these if the Modal URL or API key changes.
# -------------------------------------------------------------------

PROJECT_ROOT = Path(__file__).resolve().parent.parent


def load_env_file() -> dict[str, str]:
    env_file_path = PROJECT_ROOT / ".env"
    if not env_file_path.exists():
        return {}

    parsed_values: dict[str, str] = {}
    for raw_line in env_file_path.read_text(encoding="utf-8").splitlines():
        trimmed_line = raw_line.strip()
        if not trimmed_line or trimmed_line.startswith("#"):
            continue
        if trimmed_line.startswith("export "):
            trimmed_line = trimmed_line[len("export "):]
        if "=" not in trimmed_line:
            continue

        key, value = trimmed_line.split("=", 1)
        parsed_values[key.strip()] = value.strip().strip('"')

    return parsed_values


ENV_VALUES = load_env_file()


def env_value(key: str, default: str = "") -> str:
    return os.environ.get(key) or ENV_VALUES.get(key, default)


MOLMO_SERVER_URL = env_value("CLICKY_MOLMO_BASE_URL", "https://replace-me.modal.run")
MOLMO_API_KEY = env_value("CLICKY_MOLMO_API_KEY")

REAL_SCREENSHOT_PATH = str(PROJECT_ROOT.parent / "test.png")
REAL_SCREENSHOT_LABEL = "a clickable button or link"

# A valid 1x1 transparent PNG, base64-encoded. Used for the transport sanity
# test — if this doesn't work, the issue is in the pipeline, not your image.
TINY_PNG_BASE64 = (
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNgAAIAAAUAAen63vIAAAAASUVORK5CYII="
)

# Long timeout — the FIRST /ground call after a cold start has to load
# the 16 GB MolmoWeb-4B model into GPU memory, which takes 30-90 seconds.
REQUEST_TIMEOUT_SECONDS = 600


def print_banner(title: str) -> None:
    separator = "=" * 70
    print()
    print(separator)
    print(f"  {title}")
    print(separator)


def http_get_json(url: str, headers: dict) -> tuple[int, dict | str]:
    """Sends a GET request and returns (status_code, parsed_json_or_raw_text)."""
    request_object = urllib_request.Request(url=url, method="GET", headers=headers)
    try:
        with urllib_request.urlopen(request_object, timeout=REQUEST_TIMEOUT_SECONDS) as response:
            raw_body_bytes = response.read()
            raw_body_text = raw_body_bytes.decode("utf-8", errors="replace")
            try:
                return response.status, json.loads(raw_body_text)
            except json.JSONDecodeError:
                return response.status, raw_body_text
    except HTTPError as http_error:
        raw_body_bytes = http_error.read()
        raw_body_text = raw_body_bytes.decode("utf-8", errors="replace")
        return http_error.code, raw_body_text
    except URLError as url_error:
        return 0, f"URLError: {url_error}"


def http_post_json(url: str, headers: dict, body_dict: dict) -> tuple[int, dict | str]:
    """Sends a POST request with a JSON body and returns (status_code, parsed_body)."""
    serialized_body_bytes = json.dumps(body_dict).encode("utf-8")
    full_headers = {
        **headers,
        "Content-Type": "application/json",
        "Content-Length": str(len(serialized_body_bytes)),
    }
    request_object = urllib_request.Request(
        url=url,
        method="POST",
        headers=full_headers,
        data=serialized_body_bytes,
    )
    try:
        with urllib_request.urlopen(request_object, timeout=REQUEST_TIMEOUT_SECONDS) as response:
            raw_body_bytes = response.read()
            raw_body_text = raw_body_bytes.decode("utf-8", errors="replace")
            try:
                return response.status, json.loads(raw_body_text)
            except json.JSONDecodeError:
                return response.status, raw_body_text
    except HTTPError as http_error:
        raw_body_bytes = http_error.read()
        raw_body_text = raw_body_bytes.decode("utf-8", errors="replace")
        return http_error.code, raw_body_text
    except URLError as url_error:
        return 0, f"URLError: {url_error}"


def check_health() -> bool:
    """Pings /health — no auth required, no model load triggered.
    Returns True on 2xx."""
    print_banner("Step 1: GET /health")

    status_code, response_body = http_get_json(
        url=f"{MOLMO_SERVER_URL}/health",
        headers={},
    )

    print(f"HTTP {status_code}")
    print(f"Response: {response_body}")

    if 200 <= status_code < 300:
        print("✅ Health check passed — server is reachable.")
        return True
    else:
        print("❌ Health check failed — server is NOT reachable.")
        print("   If this is a new container, it may still be booting. Wait 30s and retry.")
        return False


def test_ground_tiny_png() -> bool:
    """Sends a 1x1 PNG to /ground. Validates the transport + PIL decoder path.
    Returns True on 2xx."""
    print_banner("Step 2: POST /ground  (tiny 1x1 PNG)")

    print(f"Base64 length: {len(TINY_PNG_BASE64)} chars")
    print(f"This is the FIRST /ground call, so the container will need to load")
    print(f"MolmoWeb-4B into GPU memory. Expect 30-120 seconds. Hang tight.")
    print()

    call_start_time = time.time()
    status_code, response_body = http_post_json(
        url=f"{MOLMO_SERVER_URL}/ground",
        headers={"Authorization": f"Bearer {MOLMO_API_KEY}"},
        body_dict={
            "screenshot_base64": TINY_PNG_BASE64,
            "element_label": "a pixel",
        },
    )
    call_duration_seconds = time.time() - call_start_time

    print(f"HTTP {status_code}  (took {call_duration_seconds:.1f} sec)")
    print(f"Response: {response_body}")

    if 200 <= status_code < 300:
        print("✅ Tiny PNG test passed — base64 transport and PIL decode both work.")
        return True
    else:
        print("❌ Tiny PNG test failed — paste this output + modal app logs.")
        return False


def test_ground_real_screenshot() -> bool:
    """Sends the real test.png to /ground with a meaningful grounding label.
    This is the 'does MolmoWeb do the right thing?' test."""
    print_banner("Step 3: POST /ground  (real screenshot)")

    if not os.path.exists(REAL_SCREENSHOT_PATH):
        print(f"❌ File not found: {REAL_SCREENSHOT_PATH}")
        print("   Skipping real-screenshot test.")
        print("   Tip: take one with `screencapture -x /Users/deepeshbansal/clicky_loom/test.png`")
        return False

    file_size_bytes = os.path.getsize(REAL_SCREENSHOT_PATH)
    print(f"File: {REAL_SCREENSHOT_PATH}")
    print(f"Size: {file_size_bytes:,} bytes")

    with open(REAL_SCREENSHOT_PATH, "rb") as screenshot_file:
        screenshot_bytes = screenshot_file.read()

    screenshot_base64 = base64.b64encode(screenshot_bytes).decode("ascii")
    print(f"Base64 length: {len(screenshot_base64):,} chars")
    print(f"Base64 prefix: {screenshot_base64[:32]}...")
    print()

    call_start_time = time.time()
    status_code, response_body = http_post_json(
        url=f"{MOLMO_SERVER_URL}/ground",
        headers={"Authorization": f"Bearer {MOLMO_API_KEY}"},
        body_dict={
            "screenshot_base64": screenshot_base64,
            "element_label": REAL_SCREENSHOT_LABEL,
        },
    )
    call_duration_seconds = time.time() - call_start_time

    print(f"HTTP {status_code}  (took {call_duration_seconds:.1f} sec)")
    print()
    print("Raw response:")
    print(json.dumps(response_body, indent=2) if isinstance(response_body, dict) else response_body)
    print()

    if 200 <= status_code < 300:
        if isinstance(response_body, dict) and "raw_output" in response_body:
            print("✅ Real screenshot test passed.")
            print()
            print("=" * 70)
            print("  MolmoWeb raw_output (this is what the Swift parser has to handle):")
            print("=" * 70)
            print(response_body["raw_output"])
            print("=" * 70)
            return True
        else:
            print("⚠️ Got 2xx but response shape is unexpected — paste this output.")
            return False
    else:
        print("❌ Real screenshot test failed.")
        return False


def main() -> int:
    if not MOLMO_API_KEY:
        print("Missing CLICKY_MOLMO_API_KEY. Add it to .env or export it before running this test.")
        return 1

    masked_api_key = (
        f"{MOLMO_API_KEY[:8]}...{MOLMO_API_KEY[-8:]}"
        if len(MOLMO_API_KEY) >= 16
        else "(set)"
    )

    print(f"MOLMO_SERVER_URL: {MOLMO_SERVER_URL}")
    print(f"MOLMO_API_KEY:    {masked_api_key}")
    print(f"Python version:   {sys.version.split()[0]}")
    print(f"Test file:        {REAL_SCREENSHOT_PATH}")

    if not check_health():
        return 1

    if not test_ground_tiny_png():
        return 2

    if not test_ground_real_screenshot():
        return 3

    print()
    print("🎉 All three tests passed. MolmoWeb grounding pipeline is working end-to-end.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
