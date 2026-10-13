#!/usr/bin/env python3
"""Local GitHub App manifest handshake; credentials never appear in terminal output."""
import argparse
import html
import json
import os
from pathlib import Path
import secrets
import subprocess
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs, urlparse


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--owner", default="kxw9298")
    parser.add_argument("--name", default="kxw9298-aks-runner-poc")
    args = parser.parse_args()
    state_dir = Path(__file__).resolve().parent.parent / ".poc-state"
    state_dir.mkdir(mode=0o700, exist_ok=True)
    os.chmod(state_dir, 0o700)
    if (state_dir / "github-app.pem").exists():
        parser.error("An App key already exists in .poc-state; use the existing App rather than overwrite it.")
    nonce = secrets.token_urlsafe(32)
    origin = f"http://127.0.0.1:{args.port}"
    manifest = json.loads((Path(__file__).parent / "github-app-manifest.json").read_text())
    manifest.update(
        name=args.name,
        url=f"https://github.com/{args.owner}/aks-github-runners",
        redirect_url=f"{origin}/callback?state={nonce}",
    )

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass  # The callback URL contains a one-time credential exchange code.

        def respond(self, status, content):
            body = content.encode()
            self.send_response(status)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            request = urlparse(self.path)
            params = parse_qs(request.query)
            if params.get("state") != [nonce]:
                self.respond(403, "Invalid setup session.")
                return
            if request.path == "/":
                self.respond(200, f"""<!doctype html><html><title>AKS runner App setup</title>
                <body><h1>Register the PoC GitHub App</h1>
                <p>Private App: {html.escape(args.name)}.</p>
                <p>Repository administration: read/write. Metadata: read.
                No code-content permission, org permission, or webhook.</p>
                <p>After registration, install on <strong>aks-github-runners only</strong>.</p>
                <form method="post" action="https://github.com/settings/apps/new">
                <input type="hidden" name="manifest" value="{html.escape(json.dumps(manifest), quote=True)}">
                <button type="submit">Continue to GitHub</button></form></body></html>""")
                return
            if request.path != "/callback" or not params.get("code"):
                self.respond(404, "Unknown setup step.")
                return
            result = subprocess.run(
                ["gh", "api", "--method", "POST", f"/app-manifests/{params['code'][0]}/conversions"],
                capture_output=True, text=True, check=False,
            )
            if result.returncode:
                self.respond(502, "GitHub credential exchange failed. Retry registration; no credentials logged.")
                return
            app = json.loads(result.stdout)
            key_path = state_dir / "github-app.pem"
            metadata_path = state_dir / "github-app.json"
            for target, content in (
                (key_path, app["pem"]),
                (metadata_path, json.dumps({k: app[k] for k in ("id", "slug", "html_url")}, indent=2)),
            ):
                fd = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
                os.fchmod(fd, 0o600)
                with os.fdopen(fd, "w") as output:
                    output.write(content)
            install_url = f"https://github.com/apps/{app['slug']}/installations/new"
            self.respond(200, f"""<!doctype html><html><title>App registered</title><body>
                <h1>GitHub App registered</h1><p>App ID: {app['id']}</p>
                <p>The private key was saved securely to the local ignored .poc-state directory.</p>
                <p><a href="{html.escape(install_url, quote=True)}">Install the App</a>.
                Choose <strong>Only select repositories → aks-github-runners</strong>.</p>
                <p>Record the installation ID from the resulting installation-settings URL.</p>
                </body></html>""")
            print(f"App registered. ID: {app['id']}. Install URL: {install_url}", flush=True)

    server = HTTPServer(("127.0.0.1", args.port), Handler)
    print(f"Open {origin}/?state={nonce}", flush=True)
    print("Keep this process running through registration. Stop with Ctrl-C after installation.", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
