"""Replaceable, fixed-purpose online timezone provider."""
import json
from pathlib import Path
import urllib.error
import urllib.parse
import urllib.request

PROVIDER_CONFIG = Path("/etc/4tw/timezone-provider.json")
MAX_RESPONSE = 128


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, file_pointer, code, message, headers, new_url):
        return None


def load_provider(path=PROVIDER_CONFIG):
    data = json.loads(path.read_text())
    if set(data) != {"name", "endpoint", "response", "timeout_seconds"}:
        raise ValueError("Unexpected provider configuration")
    endpoint = data["endpoint"]
    parsed = urllib.parse.urlsplit(endpoint)
    if (data["name"] != "ipapi.co" or data["response"] != "iana-text" or
            data["timeout_seconds"] not in {3, 4, 5} or parsed.scheme != "https" or
            parsed.hostname != "ipapi.co" or parsed.port not in (None, 443) or
            parsed.username is not None or parsed.password is not None or
            parsed.query or parsed.fragment or parsed.path != "/timezone/"):
        raise ValueError("Unsafe provider configuration")
    return endpoint, data["timeout_seconds"]


def parse_response(data):
    if not isinstance(data, bytes) or not data or len(data) > MAX_RESPONSE:
        return None
    try:
        decoded = data.decode("utf-8", errors="strict")
    except UnicodeError:
        return None
    value = decoded.rstrip("\r\n")
    # The configured endpoint is deliberately plain text. JSON (valid or
    # malformed), HTML, multiple lines and control characters are rejected.
    if (not value or value != value.strip() or value.startswith(("{", "[", "<")) or
            any(ord(char) < 32 or ord(char) == 127 for char in value)):
        return None
    return value


def lookup_timezone(config_path=PROVIDER_CONFIG, opener=None):
    try:
        endpoint, timeout = load_provider(config_path)
        request = urllib.request.Request(
            endpoint,
            headers={"Accept": "text/plain", "User-Agent": "4TW-OS-Timezone/1"},
            method="GET",
        )
        client = opener or urllib.request.build_opener(NoRedirect())
        with client.open(request, timeout=timeout) as response:
            if response.status != 200:
                return None
            return parse_response(response.read(MAX_RESPONSE + 1))
    except (OSError, TimeoutError, ValueError, json.JSONDecodeError,
            urllib.error.HTTPError, urllib.error.URLError):
        return None
