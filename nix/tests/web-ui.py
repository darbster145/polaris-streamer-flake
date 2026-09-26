#!/usr/bin/env python3
"""Exercise first-run credentials and authenticated configuration as a build user."""

import argparse
import http.cookiejar
import html.parser
import json
import os
from pathlib import Path
import re
import secrets
import signal
import socket
import ssl
import stat
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request


class CheckFailure(Exception):
    pass


class CsrfParser(html.parser.HTMLParser):
    token = None

    def handle_starttag(self, tag, attributes):
        attrs = dict(attributes)
        if tag == "meta" and attrs.get("name") == "csrf-token":
            self.token = attrs.get("content")


def client():
    jar = http.cookiejar.CookieJar()
    # The isolated server generates its own localhost certificate.
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    context.check_hostname = False
    context.verify_mode = ssl.CERT_NONE
    opener = urllib.request.build_opener(
        urllib.request.ProxyHandler({}),
        urllib.request.HTTPSHandler(context=context),
        urllib.request.HTTPCookieProcessor(jar),
    )
    return opener, jar


def request(opener, base_url, path, payload=None, csrf=None):
    headers = {"Accept": "application/json"}
    body = None
    if payload is not None:
        headers["Content-Type"] = "application/json"
        body = json.dumps(payload).encode()
    if csrf:
        headers["X-CSRF-Token"] = csrf
    req = urllib.request.Request(base_url + path, data=body, headers=headers)
    try:
        with opener.open(req, timeout=2) as response:
            return response.status, response.read(4 * 1024 * 1024)
    except urllib.error.HTTPError as error:
        error.close()
        return error.code, b""


def require_success(opener, base_url, path, payload=None, csrf=None):
    status, body = request(opener, base_url, path, payload, csrf)
    if status != 200:
        raise CheckFailure(f"{path} returned HTTP {status}, expected 200")
    try:
        document = json.loads(body)
    except (ValueError, UnicodeError):
        raise CheckFailure(f"{path} did not return JSON") from None
    if not isinstance(document, dict) or document.get("status") is not True:
        raise CheckFailure(f"{path} did not return status=true")


def stop(process):
    if process is None:
        return
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    try:
        process.wait(timeout=8)
    except subprocess.TimeoutExpired:
        pass
    # Remove any surviving child in this test's new process group only.
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    process.wait(timeout=5)


def failure_log(log_path, private_values, directory):
    lines = log_path.read_text(errors="replace").splitlines()[-35:]
    print("Sanitized server log tail:", file=sys.stderr)
    for line in lines:
        # Never reproduce generated configuration, headers, or request payloads.
        if re.search(r"config:|cookie|authorization|password|username|csrf|token|\bpayload\b", line, re.I):
            continue
        if re.search(r"[{}]", line):
            continue
        for value in private_values:
            if value:
                line = line.replace(value, "<redacted>")
        line = line.replace(str(directory), "<test-directory>")
        line = re.sub(r"[A-Za-z0-9_+/=-]{32,}", "<redacted>", line)
        line = "".join(character for character in line if character.isprintable())
        print(line[:500], file=sys.stderr)


def path_diagnostics(directory, env):
    """Describe only directory ownership/modes, never private file contents."""
    print(f"Private-state path metadata (effective uid {os.geteuid()}):", file=sys.stderr)
    paths = set()
    for path in (Path(env["XDG_CONFIG_HOME"]) / "polaris", Path(env["RUNTIME_DIRECTORY"])):
        if not path.is_absolute():
            path = directory / path
        paths.add(path)
        paths.update(path.parents)
    for path in sorted(paths, key=lambda item: (len(item.parts), str(item))):
        label = str(path).replace(str(directory), "<test-directory>")
        try:
            metadata = path.lstat()
            print(f"{label}: uid={metadata.st_uid} mode={stat.filemode(metadata.st_mode)}", file=sys.stderr)
        except OSError as error:
            print(f"{label}: stat errno={error.errno}", file=sys.stderr)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prepare", required=True)
    parser.add_argument("--launcher", required=True)
    parser.add_argument("--port", required=True, type=int)
    args = parser.parse_args()
    if not 1024 <= args.port <= 65514:
        parser.error("--port must leave room for Polaris's service port offsets")

    with tempfile.TemporaryDirectory(prefix="polaris-web-ui-") as temporary:
        # Polaris securely walks every component with O_NOFOLLOW. Nix and
        # macOS can expose TMPDIR through a symlink, so use its physical path.
        directory = Path(temporary).resolve(strict=True)
        directory.chmod(0o700)
        # Start from a minimal environment, so no live desktop, session bus,
        # service credentials, or application configuration can be inherited.
        env = {key: os.environ[key] for key in ("PATH", "LANG", "LC_ALL", "TZ", "TMPDIR", "LD_LIBRARY_PATH") if key in os.environ}
        for key in ("HOME", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_CACHE_HOME", "XDG_STATE_HOME", "XDG_RUNTIME_DIR"):
            path = directory / key.lower()
            path.mkdir(mode=0o700)
            env[key] = str(path)
        runtime = Path(env["XDG_RUNTIME_DIR"]) / "polaris-stream"
        runtime.mkdir(mode=0o700)
        env["RUNTIME_DIRECTORY"] = str(runtime)
        env["POLARIS_MIGRATE_CONFIG"] = "0"
        if Path("/").stat().st_uid not in (0, os.geteuid()):
            # A Nix user namespace can expose / as uid 65534 (unmapped),
            # which Polaris correctly refuses as an ancestor of private
            # state. Its secure walker also supports relative paths: start
            # at our owned cwd, retaining every ownership/mode/link check.
            # Normal hosts still exercise absolute XDG and runtime paths.
            for key in ("XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_CACHE_HOME", "XDG_STATE_HOME", "XDG_RUNTIME_DIR", "RUNTIME_DIRECTORY"):
                env[key] = str(Path(env[key]).relative_to(directory))

        process = None
        jars = []
        password = secrets.token_urlsafe(32)
        private_values = [password]
        log_path = directory / "server.log"
        failed = False
        try:
            # Refuse an occupied endpoint before any credential request could
            # accidentally reach a server outside this test.
            with socket.socket() as probe:
                probe.bind(("127.0.0.1", args.port + 1))
            with log_path.open("wb") as log:
                subprocess.run([args.prepare], env=env, cwd=directory, stdout=log, stderr=subprocess.STDOUT, check=True, timeout=15)
                process = subprocess.Popen([args.launcher], env=env, cwd=directory, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
                opener, jar = client()
                jars.append(jar)
                base_url = f"https://127.0.0.1:{args.port + 1}"
                deadline = time.monotonic() + 37
                csrf = None
                while time.monotonic() < deadline:
                    if process.poll() is not None:
                        raise CheckFailure("Polaris exited before its Web UI was ready")
                    try:
                        status, page = request(opener, base_url, "/welcome")
                        if status == 200:
                            html = CsrfParser()
                            html.feed(page.decode("utf-8", errors="replace"))
                            csrf = html.token
                            if csrf:
                                break
                    except (urllib.error.URLError, TimeoutError, OSError):
                        pass
                    time.sleep(0.2)
                if not csrf:
                    raise CheckFailure("Web UI with CSRF metadata was not ready within 40 seconds")
                private_values.append(csrf)
                credentials = {"username": "nix-web-ui-test", "password": password}
                require_success(opener, base_url, "/api/password", {
                    "newUsername": credentials["username"],
                    "newPassword": password,
                    "confirmNewPassword": password,
                }, csrf)
                if not list(jar):
                    raise CheckFailure("Credential creation did not issue a session cookie")
                require_success(opener, base_url, "/api/config")

                opener, jar = client()
                jars.append(jar)
                # Upstream login succeeds with an empty 200 response; its
                # cookie and the authenticated config request prove success.
                status, _ = request(opener, base_url, "/api/login", credentials)
                if status != 200:
                    raise CheckFailure(f"/api/login returned HTTP {status}, expected 200")
                if not list(jar):
                    raise CheckFailure("Fresh login did not issue a session cookie")
                require_success(opener, base_url, "/api/config")
        except (CheckFailure, OSError, ValueError, subprocess.SubprocessError) as error:
            failed = True
            # Only our own fixed diagnostics are safe to show; subprocess and
            # transport exceptions can include arguments, URLs, or payloads.
            detail = str(error) if isinstance(error, CheckFailure) else type(error).__name__
            print(f"Web UI regression check failed: {detail}", file=sys.stderr)
        finally:
            stop(process)
            if failed and log_path.exists():
                private_values.extend(cookie.value for jar in jars for cookie in jar)
                failure_log(log_path, private_values, directory)
                path_diagnostics(directory, env)
        if failed:
            return 1
    print("Web UI credential creation, fresh login, and authenticated configuration checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
