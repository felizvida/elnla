#!/usr/bin/env python3
"""Local LabArchives GOV auth helper.

Starts a localhost callback, opens or saves the API login URL, captures the
one-time auth_code, exchanges it for user access info, and stores the raw
response in local_credentials/. Do not commit the generated local files.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import hmac
import http.server
import os
from pathlib import Path
import ssl
import sys
import time
from typing import Dict
from urllib import parse, request
import webbrowser


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_ENV = ROOT / "local_credentials" / "labarchives.env"
DEFAULT_LOGIN_URL_OUTPUT = ROOT / "local_credentials" / "labarchives_login_url.txt"
DEFAULT_OUTPUT = ROOT / "local_credentials" / "user_access_info.xml"
BASE_URL = "https://api.labarchives-gov.com"


def load_env(path: Path) -> Dict[str, str]:
    values: Dict[str, str] = {}
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key.strip()] = value.strip().strip('"').strip("'")
    return values


def sign(access_id: str, access_key: str, method: str, expires_ms: str) -> str:
    message = f"{access_id}{method}{expires_ms}".encode("utf-8")
    digest = hmac.new(access_key.encode("utf-8"), message, hashlib.sha1).digest()
    return base64.b64encode(digest).decode("ascii")


def authenticated_get(
    api_class: str,
    method: str,
    params: Dict[str, str],
    access_id: str,
    access_key: str,
) -> bytes:
    expires_ms = f"{int(time.time())}000"
    sig = sign(access_id, access_key, method, expires_ms)
    query = {
        **params,
        "akid": access_id,
        "expires": expires_ms,
        "sig": sig,
    }
    url = f"{BASE_URL}/api/{api_class}/{method}?{parse.urlencode(query)}"
    req = request.Request(url, headers={"User-Agent": "elnla-local-auth/0.1"})
    context = ssl.create_default_context()
    with request.urlopen(req, timeout=30, context=context) as response:
        return response.read()


def build_login_url(access_id: str, access_key: str, redirect_uri: str) -> str:
    expires_ms = f"{int(time.time())}000"
    sig = sign(access_id, access_key, redirect_uri, expires_ms)
    query = parse.urlencode(
        {
            "akid": access_id,
            "expires": expires_ms,
            "redirect_uri": redirect_uri,
            "sig": sig,
        }
    )
    return f"{BASE_URL}/api_user_login?{query}"


def wait_for_callback(host: str, port: int, path: str) -> Dict[str, str]:
    result: Dict[str, str] = {}

    class CallbackHandler(http.server.BaseHTTPRequestHandler):
        def do_GET(self) -> None:  # noqa: N802 - stdlib method name
            parsed = parse.urlparse(self.path)
            if parsed.path != path:
                self.send_response(404)
                self.end_headers()
                self.wfile.write(b"Not found")
                return

            qs = parse.parse_qs(parsed.query)
            for key, values in qs.items():
                if values:
                    result[key] = values[0]

            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.end_headers()
            self.wfile.write(
                b"LabArchives authorization captured. You can return to Codex."
            )

        def log_message(self, format: str, *args: object) -> None:
            return

    server = http.server.ThreadingHTTPServer((host, port), CallbackHandler)
    server.timeout = 300
    while not result:
        server.handle_request()
    server.server_close()
    return result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--email", required=True)
    parser.add_argument("--env", type=Path, default=DEFAULT_ENV)
    parser.add_argument("--login-url-output", type=Path, default=DEFAULT_LOGIN_URL_OUTPUT)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--path", default="/labarchives_callback")
    parser.add_argument("--open-browser", action="store_true")
    parser.add_argument("--print-url", action="store_true")
    args = parser.parse_args()

    env = load_env(args.env)
    access_id = env.get("LABARCHIVES_GOV_LOGIN_ID")
    access_key = env.get("LABARCHIVES_GOV_ACCESS_KEY")
    if not access_id or not access_key:
        print("Missing LabArchives credentials in local env file.", file=sys.stderr)
        return 2

    redirect_uri = f"http://{args.host}:{args.port}{args.path}"
    login_url = build_login_url(access_id, access_key, redirect_uri)

    args.login_url_output.parent.mkdir(parents=True, exist_ok=True)
    args.login_url_output.write_text(login_url, encoding="utf-8")
    os.chmod(args.login_url_output, 0o600)

    if args.print_url:
        print(login_url)
    elif args.open_browser:
        opened = webbrowser.open(login_url)
        if opened:
            print("Opened the LabArchives login URL in your default browser.")
        else:
            print(
                "Could not open the browser automatically. "
                f"Login URL saved to {args.login_url_output.relative_to(ROOT)}."
            )
    else:
        print(f"Login URL saved to {args.login_url_output.relative_to(ROOT)}.")

    print("Waiting for localhost callback...")
    callback = wait_for_callback(args.host, args.port, args.path)

    if "error" in callback:
        print(f"LabArchives returned an error: {callback['error']}", file=sys.stderr)
        return 1

    auth_code = callback.get("auth_code")
    callback_email = callback.get("email") or args.email
    if not auth_code:
        print("No auth_code was returned by LabArchives.", file=sys.stderr)
        return 1

    response = authenticated_get(
        "users",
        "user_access_info",
        {"login_or_email": callback_email, "password": auth_code},
        access_id,
        access_key,
    )

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(response)
    os.chmod(args.output, 0o600)
    print(f"Saved user access XML to {args.output.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
