#!/usr/bin/env python3
"""Supply Key Vault credentials transiently to Terraform's write-only arguments."""
import base64
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

root = Path(__file__).resolve().parent.parent
state = root / ".poc-state"
terraform = os.environ.get("POC_TERRAFORM") or str(state / "bin/terraform")
if not Path(terraform).exists():
    terraform = shutil.which("terraform")
if not terraform:
    raise SystemExit("Install Terraform 1.11 or newer.")
metadata = json.loads((state / "github-app.json").read_text())
values = {
    "github-app-credentials": json.dumps({
        "github_app_id": str(metadata["id"]),
        "github_app_installation_id": str(metadata["installation_id"]),
        "github_app_private_key": (state / "github-app.pem").read_text(),
    }),
}
config_file = root / "poc/terraform/credentials/terraform.tfvars.json"
config = json.loads(config_file.read_text()) if config_file.exists() else {}
if config.get("include_aks_recovery_credentials", False):
    values.update({
        "aks-kubeconfig": base64.b64encode((state / "kubeconfig").read_bytes()).decode(),
        "aks-ssh-private-key": base64.b64encode((state / "id_rsa").read_bytes()).decode(),
    })
environment = os.environ.copy()
environment["TF_VAR_secret_values"] = json.dumps(values)
os.umask(0o077)
if environment.get("TF_LOG") or environment.get("TF_LOG_PROVIDER"):
    raise SystemExit("Disable Terraform debug logging before handling credentials.")
command = [terraform, f"-chdir={root / 'poc/terraform/credentials'}", *sys.argv[1:]]
if len(sys.argv) == 1:
    raise SystemExit("Usage: python3 poc/manage-credentials.py <Terraform command and arguments>")
raise SystemExit(subprocess.run(command, env=environment).returncode)
