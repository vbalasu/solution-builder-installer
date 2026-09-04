#!/usr/bin/env python3
# ============================================================================
# workspace-setup.py — deterministic, PURE-PYTHON Solution Builder installer.
#
# Runs anywhere the Databricks SDK runs — a laptop, CI, or a Databricks
# NOTEBOOK / WORKFLOW. It uses NO bash, NO git, and NO local build toolchain:
# every workspace operation goes through the Databricks SDK (with raw REST via
# the SDK's ApiClient for the Beta Lakebase "projects" API), and the app is
# deployed from a PREBUILT artifact via the Apps SDK.
#
# Reads EVERYTHING from config.yaml. No install value is accepted on the CLI.
#
# What it does, in order:
#   1. Connect + verify auth (profile, env vars, or notebook ambient auth)
#   2. Log the install context (non-fatal telemetry)
#   3. Stage the prebuilt app artifact (a `.build` dir or a .zip of it)
#   4. Verify the chosen serving endpoints are actually CALLABLE
#   5. Provision (or reuse) Lakebase (projects/branches API, via REST)
#   6. Create/reuse the deployer service principal (+ OAuth secret)
#   7. Generate app.yml env for THIS workspace (endpoints, catalog, SP, …)
#   8. Upload the source into the workspace
#   9. Create/update the app with the EXACT 13 user_api_scopes
#  10. Deploy the app (Apps SDK, snapshot of the uploaded source)
#  11. Wire the app's service principal to Lakebase (grant + Postgres role)
#  12. Start the app and print its URL
#
# CLI:
#   ./workspace-setup.py                 # reads ./config.yaml
#   ./workspace-setup.py --config x.yaml
#   ./workspace-setup.py --dry-run
#
# Notebook (pure Python, no bash):
#   %pip install databricks-sdk pyyaml
#   import importlib.util
#   spec = importlib.util.spec_from_file_location("ws", "/Volumes/.../workspace-setup.py")
#   ws = importlib.util.module_from_spec(spec); spec.loader.exec_module(ws)
#   ws.run("/Volumes/.../config.yaml")
# ============================================================================
from __future__ import annotations

import argparse
import os
import re
import sys
import tempfile
import time
import zipfile
from pathlib import Path
from typing import NoReturn

# ── canonical scope set (base reads + the 10 explicit build scopes = 13) ──────
# See references/scopes.md. NEVER `all-apis`. In the DAB path DAB appends the
# build scopes to the base; here we set the full resolved list explicitly.
BASE_SCOPES = ["catalog.catalogs", "catalog.schemas", "catalog.tables"]
BUILD_SCOPES = [
    "sql", "genie", "postgres", "workspace.workspace", "files", "apps",
    "model-serving", "ai-gateway", "vector-search", "catalog.connections",
]
ALL_SCOPES = BASE_SCOPES + BUILD_SCOPES

# ── pretty output ──────────────────────────────────────────────────────────────
_TTY = sys.stdout.isatty()
def _c(code: str) -> str: return code if _TTY else ""
RESET, BOLD, DIM = _c("\033[0m"), _c("\033[1m"), _c("\033[2m")
GREEN, BLUE, YELLOW, RED = _c("\033[0;32m"), _c("\033[0;34m"), _c("\033[1;33m"), _c("\033[0;31m")

def banner(msg: str) -> None:
    line = "═" * 68
    print(f"\n{BOLD}{BLUE}{line}\n {msg}\n{line}{RESET}")
def step(msg: str) -> None: print(f"\n{BOLD}{BLUE}▸ {msg}{RESET}")
def ok(msg: str) -> None:   print(f"{GREEN}✓{RESET} {msg}")
def warn(msg: str) -> None: print(f"{YELLOW}!{RESET} {msg}")
def info(msg: str) -> None: print(f"{DIM}·{RESET} {msg}")
def hr() -> None:           print(f"{DIM}{'─' * 68}{RESET}")
def die(msg: str, code: int = 1) -> NoReturn:
    print(f"{RED}✗ {msg}{RESET}", file=sys.stderr)
    raise SystemExit(code)


# ── YAML loading (PyYAML if present, else a small subset parser) ──────────────
def load_yaml(path: Path) -> dict:
    text = path.read_text()
    try:
        import yaml  # type: ignore
        data = yaml.safe_load(text)
    except ModuleNotFoundError:
        data = _mini_yaml(text)
    if not isinstance(data, dict):
        die(f"{path} did not parse to a mapping.")
    return data

def _coerce(v: str):
    s = v.strip()
    if len(s) >= 2 and s[0] in "\"'" and s[-1] == s[0]:
        return s[1:-1]
    low = s.lower()
    if low in ("true", "yes"):   return True
    if low in ("false", "no"):   return False
    if low in ("null", "~", ""): return None
    if re.fullmatch(r"-?\d+", s):      return int(s)
    if re.fullmatch(r"-?\d+\.\d+", s): return float(s)
    return s

def _mini_yaml(text: str) -> dict:
    """Minimal YAML for this repo's flat/nested-map config (no lists)."""
    root: dict = {}
    stack = [(-1, root)]
    for raw in text.splitlines():
        line = raw if not raw.lstrip().startswith("#") else ""
        line = re.split(r"\s#", line, maxsplit=1)[0].rstrip()
        if not line.strip():
            continue
        indent = len(line) - len(line.lstrip(" "))
        key, _, val = line.strip().partition(":")
        while stack and indent <= stack[-1][0]:
            stack.pop()
        parent = stack[-1][1]
        if val.strip() == "":
            child: dict = {}
            parent[key.strip()] = child
            stack.append((indent, child))
        else:
            parent[key.strip()] = _coerce(val)
    return root


# ── config ──────────────────────────────────────────────────────────────────
class Config:
    def __init__(self, data: dict, path: Path):
        self.path = path
        dbx = _sect(data, "databricks")
        self.workspace_url = str(dbx.get("workspace_url", "")).rstrip("/")
        self.profile = str(dbx.get("profile", "") or "")

        art = _sect(data, "artifact")
        self.artifact_path = (path.parent / str(art.get("path") or "")).resolve() if art.get("path") else None
        self.ws_source_path = str(art.get("workspace_source_path") or "")

        app = _sect(data, "app")
        self.app_name = str(app.get("name") or "")
        self.default_catalog = str(app.get("default_catalog") or "")

        lb = _sect(data, "lakebase")
        self.lb_project = str(lb.get("project_id") or "")
        self.lb_reuse = bool(lb.get("reuse_existing", False))

        ep = _sect(data, "endpoints")
        self.ep_llm = str(ep.get("anthropic_llm_endpoint") or "")
        self.ep_base_path = str(ep.get("anthropic_base_path") or "serving-endpoints/anthropic")
        self.ep_gw = str(ep.get("ai_gateway") or "")
        self.ep_gw_mini = str(ep.get("ai_gateway_mini") or "")
        self.ep_gw_emb = str(ep.get("ai_gateway_embedding") or "")

        sp = _sect(data, "deployer_sp")
        self.sp_enabled = bool(sp.get("enabled", True))
        self.sp_name = str(sp.get("name") or "solution-builder-deployer")
        self.sp_scope = str(sp.get("secret_scope") or "solution-builder")
        self.sp_key = str(sp.get("secret_key") or "deployer-sp-client-secret")
        self.sp_grant = str(sp.get("grant") or "admin")

        self.log_enabled = bool(_sect(data, "logging").get("enabled", True))

    def validate(self) -> None:
        req = {
            "databricks.workspace_url": self.workspace_url,
            "app.name": self.app_name,
            "app.default_catalog": self.default_catalog,
            "lakebase.project_id": self.lb_project,
            "endpoints.anthropic_llm_endpoint": self.ep_llm,
            "endpoints.ai_gateway": self.ep_gw,
            "endpoints.ai_gateway_mini": self.ep_gw_mini,
            "endpoints.ai_gateway_embedding": self.ep_gw_emb,
        }
        missing = [k for k, v in req.items() if not v]
        if missing:
            die("config.yaml is missing required value(s):\n    - " + "\n    - ".join(missing))
        if "your-workspace.cloud.databricks.com" in self.workspace_url:
            die("databricks.workspace_url still holds the placeholder — set your real workspace URL.")
        if not self.workspace_url.startswith("https://"):
            die(f"databricks.workspace_url must start with https:// (got: {self.workspace_url})")
        if self.sp_grant not in ("admin", "none"):
            die(f"deployer_sp.grant must be 'admin' or 'none' (got: {self.sp_grant})")
        if not self.artifact_path or not self.artifact_path.exists():
            die(f"artifact.path not found: {self.artifact_path}. Build it once on a toolchain host "
                "(see config.yaml comments) and point artifact.path at the .build dir or its .zip.")

def _sect(data: dict, name: str) -> dict:
    v = data.get(name, {})
    return v if isinstance(v, dict) else {}


# ── SDK client ────────────────────────────────────────────────────────────────
def make_client(cfg: Config):
    try:
        from databricks.sdk import WorkspaceClient
    except ModuleNotFoundError:
        die("The Databricks SDK is required. Install it:\n"
            "    pip install databricks-sdk        (laptop / CI)\n"
            "    %pip install databricks-sdk       (Databricks notebook)")
    kwargs = {}
    if cfg.profile:
        kwargs["profile"] = cfg.profile
    return WorkspaceClient(**kwargs)


# ── steps ─────────────────────────────────────────────────────────────────────
def step_auth(w, cfg: Config) -> str:
    step("Step 1/12 — Connect + verify authentication")
    from databricks.sdk.errors.base import DatabricksError
    try:
        me = w.current_user.me()
    except DatabricksError as e:
        die("Not authenticated to the workspace. Provide credentials, then re-run:\n"
            f"    • laptop:  databricks auth login --host {cfg.workspace_url} --profile {cfg.profile or '<name>'}\n"
            "    • env/CI:  export DATABRICKS_HOST + DATABRICKS_TOKEN (leave profile blank)\n"
            "    • notebook: runs on the notebook's ambient auth automatically.\n"
            f"  ({e})")
    who = me.user_name or "(unknown)"
    host = (w.config.host or cfg.workspace_url).rstrip("/")
    via = f"profile: {cfg.profile}" if cfg.profile else "ambient/env auth"
    ok(f"Signed in as: {who} ({via})")
    ok(f"Workspace host: {host}")
    if cfg.workspace_url.rstrip("/") not in (host, host.rstrip("/")):
        warn(f"config workspace_url ({cfg.workspace_url}) != connected host ({host}). Using the connected host.")
    return who

def step_log_install(w, cfg: Config, user: str) -> None:
    step("Step 2/12 — Log install context (non-fatal)")
    if not cfg.log_enabled:
        info("logging.enabled=false → skipping.")
        return
    try:
        host = (w.config.host or cfg.workspace_url).rstrip("/")
        try:
            ws_id = str(w.get_workspace_id())
        except Exception:
            ws_id = ""
        ts = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        record = (
            "solution_builder_install:\n"
            f'  timestamp: "{ts}"\n'
            f'  workspace_url: "{host}"\n'
            f'  workspace_id: "{ws_id}"\n'
            f'  user_email: "{user}"\n'
        )
        info(f"workspace_url: {host}  workspace_id: {ws_id or '<unknown>'}  user: {user}")
        _best_effort_log_upload(host, user, record)
    except Exception as e:
        warn(f"Install logging failed (non-fatal): {e}")

def _best_effort_log_upload(host: str, user: str, record: str) -> None:
    """Ship the YAML record to the shared logger bucket. Never fatal."""
    import urllib.request
    slug = re.sub(r"-+", "-", re.sub(r"[^a-z0-9]", "-", host.replace("https://", "").lower())).strip("-")
    slug = slug.split("-cloud-databricks-com")[0] or "workspace"
    uslug = re.sub(r"[^a-z0-9]", "-", (user.split("@")[0] or "user").lower()).strip("-") or "user"
    name = f"{slug}-{uslug}-{time.strftime('%Y%m%d-%H%M%S', time.gmtime())}.yml"
    url = f"https://default-logger.s3.us-east-1.amazonaws.com/logger/solution-builder-installer/{name}"
    try:
        req = urllib.request.Request(url, data=record.encode(), method="PUT",
                                     headers={"Content-Type": "text/yaml"})
        urllib.request.urlopen(req, timeout=10)
        ok(f"Logged install context (logger/solution-builder-installer/{name}).")
    except Exception:
        info("Logger upload skipped (non-fatal).")


def step_stage_artifact(cfg: Config) -> Path:
    step("Step 3/12 — Stage the prebuilt app artifact")
    src = cfg.artifact_path
    assert src is not None
    if src.is_dir():
        staged = src
        info(f"Using prebuilt directory: {staged}")
    elif src.suffix == ".zip" or zipfile.is_zipfile(src):
        staged = Path(tempfile.mkdtemp(prefix="sb-build-"))
        with zipfile.ZipFile(src) as z:
            z.extractall(staged)
        # If the zip wrapped a single top-level `.build` dir, descend into it.
        entries = [p for p in staged.iterdir() if not p.name.startswith("__")]
        if len(entries) == 1 and entries[0].is_dir() and not (staged / "app.yml").exists():
            staged = entries[0]
        info(f"Extracted {src.name} → {staged}")
    else:
        die(f"artifact.path is neither a directory nor a .zip: {src}")
    ayml = staged / "app.yml"
    if not ayml.exists():
        die(f"No app.yml at the artifact root ({staged}). Point artifact.path at a built `.build` "
            "dir (or a zip of its CONTENTS). Build it with app/scripts/build.sh on a toolchain host.")
    if not any(staged.glob("*.whl")):
        warn("No *.whl found in the artifact — is this a complete `.build`? Continuing anyway.")
    ok(f"Artifact staged at {staged}")
    return staged


def _probe_endpoint(w, name: str, kind: str) -> str:
    """OK | DISABLED | MISSING | ERROR — a tiny real query."""
    from databricks.sdk.service.serving import ChatMessage, ChatMessageRole
    try:
        if kind == "embedding":
            w.serving_endpoints.query(name, input="ping")
        else:
            w.serving_endpoints.query(
                name, messages=[ChatMessage(role=ChatMessageRole.USER, content="ping")], max_tokens=5)
        return "OK"
    except Exception as e:
        msg = str(e).lower()
        if "rate limit of 0" in msg or "temporarily disabled" in msg:
            return "DISABLED"
        if "does not exist" in msg or "not found" in msg or "resource_does_not_exist" in msg:
            return "MISSING"
        return "ERROR"

def step_check_endpoints(w, cfg: Config) -> None:
    step("Step 4/12 — Verify chosen endpoints are callable")
    checks = [
        ("anthropic_llm_endpoint", cfg.ep_llm, "chat"),
        ("ai_gateway", cfg.ep_gw, "chat"),
        ("ai_gateway_mini", cfg.ep_gw_mini, "chat"),
        ("ai_gateway_embedding", cfg.ep_gw_emb, "embedding"),
    ]
    failed = False
    for label, ep, kind in checks:
        st = _probe_endpoint(w, ep, kind)
        if st == "OK":
            ok(f"{label}: {ep} — callable")
        else:
            warn(f"{label}: {ep} — {st}")
            failed = True
    if failed:
        _print_paste_ready(w)
        die("Update config.yaml → endpoints with callable names (paste-ready block above), then re-run.")

def _discover_callable(w) -> tuple[list[str], list[str]]:
    def rank(n: str) -> int:
        order = ["claude-sonnet", "claude-haiku", "claude", "gpt-5-4-mini", "gpt-5-mini",
                 "gpt", "gemini", "llama"]
        n = n.lower()
        return next((i for i, p in enumerate(order) if p in n), len(order))
    chat, embed = [], []
    for e in w.serving_endpoints.list():
        task = getattr(e, "task", None) or ""
        if task == "llm/v1/chat":
            chat.append(e.name)
        elif task == "llm/v1/embeddings":
            embed.append(e.name)
    chat = sorted(chat, key=rank)[:25]
    info("Probing this workspace's serving endpoints for callable ones…")
    chat_ok = [n for n in chat if _probe_endpoint(w, n, "chat") == "OK"]
    embed_ok = [n for n in embed[:25] if _probe_endpoint(w, n, "embedding") == "OK"]
    return chat_ok, embed_ok

def _print_paste_ready(w) -> None:
    warn("One or more endpoints are not callable. Finding working alternatives…")
    chat_ok, embed_ok = _discover_callable(w)
    def pick(cands, needles, fallback):
        for nd in needles:
            for c in cands:
                if nd in c.lower():
                    return c
        return cands[0] if cands else fallback
    llm = pick(chat_ok, ["claude-sonnet", "claude"], "<no-callable-chat-endpoint>")
    gw = pick(chat_ok, ["claude-sonnet", "claude", "gpt"], llm)
    mini = pick(chat_ok, ["mini", "nano", "flash", "haiku", "gpt"], gw)
    emb = pick(embed_ok, ["embedding", "embed", "bge", "gte", "qwen"], "<no-callable-embedding-endpoint>")
    hr()
    print(f"{BOLD}Callable chat endpoints:{RESET}")
    for n in chat_ok or ["(none responded — check model-serving access)"]:
        print(f"  · {n}")
    print(f"{BOLD}Callable embedding endpoints:{RESET}")
    for n in embed_ok or ["(none responded — check model-serving access)"]:
        print(f"  · {n}")
    hr()
    print(f"{BOLD}Paste this into config.yaml (the `endpoints:` block):{RESET}\n")
    print("endpoints:")
    print(f"  anthropic_llm_endpoint: {llm}")
    print("  anthropic_base_path: serving-endpoints/anthropic")
    print(f"  ai_gateway: {gw}")
    print(f"  ai_gateway_mini: {mini}")
    print(f"  ai_gateway_embedding: {emb}")
    print()


def step_provision_lakebase(w, cfg: Config) -> dict:
    step("Step 5/12 — Provision Lakebase")
    from databricks.sdk.errors.base import DatabricksError
    pid = cfg.lb_project
    api = w.api_client

    def project_exists() -> bool:
        try:
            api.do("GET", f"/api/2.0/postgres/projects/{pid}")
            return True
        except DatabricksError:
            return False

    if project_exists():
        ok(f"Lakebase project '{pid}' exists — reusing it.")
    elif cfg.lb_reuse:
        die(f"Lakebase project '{pid}' not found (lakebase.reuse_existing=true).")
    else:
        info(f"Creating Lakebase project '{pid}' (defaults: autoscaling)…")
        try:
            api.do("POST", "/api/2.0/postgres/projects", query={"project_id": pid}, body={})
        except DatabricksError:
            # Fallback for a body-style create convention.
            api.do("POST", "/api/2.0/postgres/projects", body={"project_id": pid})
        for _ in range(40):
            try:
                p = api.do("GET", f"/api/2.0/postgres/projects/{pid}")
                if (p.get("status") or {}).get("default_branch"):
                    break
            except DatabricksError:
                pass
            time.sleep(6)
        ok("Project created.")

    branches = (api.do("GET", f"/api/2.0/postgres/projects/{pid}/branches") or {}).get("branches", [])
    if not branches:
        die(f"No branches found on project '{pid}'.")
    default = next((b for b in branches if (b.get("status") or {}).get("default")), branches[0])
    branch = default["branch_id"]
    ok(f"Branch: {branch}")

    dbs = (api.do("GET", f"/api/2.0/postgres/projects/{pid}/branches/{branch}/databases") or {}).get("databases", [])
    names = [(d.get("status") or {}).get("postgres_database") for d in dbs]
    db = "databricks_postgres" if "databricks_postgres" in names else (names[0] if names else "databricks_postgres")
    ok(f"Database: {db}")
    return {"project": pid, "branch": branch, "db": db,
            "path": f"projects/{pid}/branches/{branch}/databases/{db}"}


def step_deployer_sp(w, cfg: Config) -> dict | None:
    step("Step 6/12 — Deployer service principal")
    if not cfg.sp_enabled:
        warn("deployer_sp.enabled=false → AI/BI dashboards (every initial_templates/* demo) will NOT build.")
        return None
    from databricks.sdk.service import iam
    # Reuse an SP with this display name, else create one.
    sp = next((s for s in w.service_principals.list(filter=f'displayName eq "{cfg.sp_name}"')), None)
    if sp is None:
        sp = w.service_principals.create(display_name=cfg.sp_name)
        ok(f"Created SP: id={sp.id} client_id={sp.application_id}")
    else:
        ok(f"Reusing SP: id={sp.id} client_id={sp.application_id}")
    sp_id, client_id = str(sp.id), str(sp.application_id)

    if cfg.sp_grant == "admin":
        admins = next((g for g in w.groups.list(filter='displayName eq "admins"')), None)
        if admins:
            try:
                w.groups.patch(admins.id,
                    operations=[iam.Patch(op=iam.PatchOp.ADD, path="members",
                                          value=[{"value": sp_id}])],
                    schemas=[iam.PatchSchema.URN_IETF_PARAMS_SCIM_API_MESSAGES_2_0_PATCH_OP])
                ok("SP added to the 'admins' group.")
            except Exception as e:
                warn(f"Could not add SP to admins (may already be a member): {e}")
        else:
            warn("Could not find the 'admins' group — grant build privileges manually.")
    else:
        warn("deployer_sp.grant=none — ensure the SP has every build privilege templates need.")

    # Raw REST (not w.service_principal_secrets_proxy) so this works on whatever
    # databricks-sdk version the runtime ships — the typed API is absent on the
    # older SDK bundled in some Databricks runtimes.
    headers = {"Accept": "application/json", "Content-Type": "application/json"}
    try:
        headers["X-Databricks-Org-Id"] = str(w.get_workspace_id())
    except Exception:
        pass
    resp = w.api_client.do(
        "POST", f"/api/2.0/accounts/servicePrincipals/{sp_id}/credentials/secrets",
        body={"lifetime": "31536000s"}, headers=headers)
    secret = (resp or {}).get("secret")
    if not secret:
        die("Failed to mint an OAuth-M2M secret for the deployer SP.")
    try:
        w.secrets.create_scope(cfg.sp_scope)
    except Exception:
        pass  # already exists
    w.secrets.put_secret(cfg.sp_scope, cfg.sp_key, string_value=secret)
    ok(f"Secret stored: scope={cfg.sp_scope} key={cfg.sp_key} (value not shown).")
    return {"client_id": client_id, "secret": secret}


APP_ENV_STATIC = {
    "ENABLE_LOGO_BY_DEFAULT": "true",
    "OTEL_TRACES_SAMPLER": "always_on",
    "OTEL_SERVICE_NAME": "solution-builder-generator",
}

def step_configure(staged: Path, cfg: Config, lb: dict, sp: dict | None) -> None:
    step("Step 7/12 — Generate app.yml env for this workspace")
    env = {
        "AI_GATEWAY": cfg.ep_gw,
        "AI_GATEWAY_EMBEDDING": cfg.ep_gw_emb,
        "AI_GATEWAY_MINI": cfg.ep_gw_mini,
        "ANTHROPIC_BASE_PATH": cfg.ep_base_path,
        "ANTHROPIC_LLM_ENDPOINT": cfg.ep_llm,
        "DEFAULT_CATALOG": cfg.default_catalog,
        "LAKEBASE_DATABASE_PATH": lb["path"],
        **APP_ENV_STATIC,
    }
    if sp:
        env["DEPLOYER_SP_CLIENT_ID"] = sp["client_id"]
        env["DEPLOYER_SP_CLIENT_SECRET"] = sp["secret"]
        env["DEFAULT_TARGET_WORKSPACE_HOST"] = cfg.workspace_url

    ayml = staged / "app.yml"
    original = ayml.read_text().splitlines()
    # Keep every line before `env:` (comments + command:), then write our env.
    head, seen_env = [], False
    for line in original:
        if re.match(r"^\s*env:\s*$", line):
            seen_env = True
            break
        head.append(line)
    if not seen_env:
        head = original  # no env block in the artifact; append one
    lines = list(head)
    lines.append("env:")
    for k in sorted(env):
        lines.append(f'  - name: "{k}"')
        lines.append(f'    value: "{env[k]}"')
    ayml.write_text("\n".join(lines) + "\n")
    shown = ", ".join(k for k in sorted(env) if "SECRET" not in k)
    ok(f"Wrote app.yml env ({len(env)} vars: {shown}, +DEPLOYER_SP_CLIENT_SECRET hidden)"
       if sp else f"Wrote app.yml env ({len(env)} vars: {shown})")


def step_upload_source(w, cfg: Config, staged: Path, user: str) -> str:
    step("Step 8/12 — Upload the app source into the workspace")
    from databricks.sdk.service.workspace import ImportFormat
    base = cfg.ws_source_path or f"/Workspace/Users/{user}/solution-builder-src/{cfg.app_name}"
    base = base.rstrip("/")
    w.workspace.mkdirs(base)
    count = 0
    files = [p for p in staged.rglob("*") if p.is_file()]
    dirs = sorted({str((Path(base) / p.relative_to(staged)).parent) for p in files})
    for d in dirs:
        w.workspace.mkdirs(d)
    for p in files:
        target = f"{base}/{p.relative_to(staged).as_posix()}"
        w.workspace.upload(target, p.read_bytes(), format=ImportFormat.RAW, overwrite=True)
        count += 1
    ok(f"Uploaded {count} file(s) to {base}")
    return base


def step_create_app(w, cfg: Config) -> object:
    step("Step 9/12 — Create/update the app (with the 13 explicit scopes)")
    from databricks.sdk.service.apps import App
    from databricks.sdk.errors.base import DatabricksError
    try:
        existing = w.apps.get(cfg.app_name)
    except DatabricksError:
        existing = None
    if existing is None:
        info(f"Creating app '{cfg.app_name}' …")
        app = w.apps.create_and_wait(
            App(name=cfg.app_name,
                description="Solution Builder — generates Databricks demo solutions",
                user_api_scopes=ALL_SCOPES))
    else:
        info(f"App '{cfg.app_name}' exists — updating scopes.")
        try:
            w.apps.update(cfg.app_name,
                          App(name=cfg.app_name, user_api_scopes=ALL_SCOPES))
        except Exception as e:
            warn(f"Could not update scopes on the existing app (continuing): {e}")
        app = w.apps.get(cfg.app_name)
    ok(f"App ready. Service principal client id: {getattr(app, 'service_principal_client_id', '?')}")
    ok(f"Requested user_api_scopes ({len(ALL_SCOPES)}): {', '.join(ALL_SCOPES)}")
    return app


def step_deploy(w, cfg: Config, source_path: str) -> None:
    # Deploying AUTO-STARTS the app, so the SP↔Lakebase wiring (Step 10) MUST
    # already be in place or the app crashes on first boot with a Postgres
    # "password authentication failed" error.
    step("Step 11/12 — Deploy the app (snapshot of the uploaded source)")
    from databricks.sdk.service.apps import AppDeployment, AppDeploymentMode
    dep = w.apps.deploy_and_wait(
        cfg.app_name,
        AppDeployment(source_code_path=source_path, mode=AppDeploymentMode.SNAPSHOT))
    ok(f"Deployed (deployment_id={getattr(dep, 'deployment_id', '?')}).")


def step_grant_sp(w, cfg: Config, app, lb: dict) -> None:
    step("Step 10/12 — Wire the app's service principal to Lakebase (before deploy)")
    from databricks.sdk.errors.base import DatabricksError
    sp_client = getattr(app, "service_principal_client_id", None)
    if not sp_client:
        sp_client = getattr(w.apps.get(cfg.app_name), "service_principal_client_id", None)
    if not sp_client:
        warn("Could not resolve the app's service principal client id — grant Lakebase access manually.")
        return
    api = w.api_client
    pid, branch = lb["project"], lb["branch"]
    # 1) CAN_MANAGE on the Lakebase project.
    try:
        api.do("PATCH", f"/api/2.0/permissions/database-projects/{pid}",
               body={"access_control_list": [
                   {"service_principal_name": sp_client, "permission_level": "CAN_MANAGE"}]})
        ok("Granted CAN_MANAGE on the Lakebase project.")
    except DatabricksError as e:
        warn(f"Grant call returned an error (may already be granted): {e}")
    # 2) Postgres role (superuser). role-id must start with a letter → 'sp-' prefix.
    role_id = f"sp-{sp_client}"
    try:
        api.do("POST", f"/api/2.0/postgres/projects/{pid}/branches/{branch}/roles",
               query={"role_id": role_id, "replace_existing": "true"},
               body={"spec": {"identity_type": "SERVICE_PRINCIPAL", "postgres_role": sp_client,
                              "auth_method": "LAKEBASE_OAUTH_V1",
                              "membership_roles": ["DATABRICKS_SUPERUSER"]}})
        ok(f"Postgres role ensured (superuser): {role_id}")
    except DatabricksError as e:
        warn(f"create-role returned an error — verify in the Lakebase UI: {e}")


def _state_url(w, name) -> tuple[str, str]:
    a = w.apps.get(name)
    return (str(getattr(getattr(a, "app_status", None), "state", "") or ""),
            getattr(a, "url", "") or "")

def step_launch(w, cfg: Config) -> None:
    step("Step 12/12 — Verify the app is RUNNING")
    from databricks.sdk.errors.base import DatabricksError
    state, url = _state_url(w, cfg.app_name)
    su = state.upper()
    # Deploy auto-starts the app. Only intervene if it isn't already RUNNING:
    # STOPPED → start; anything else (CRASHED / ACTIVE-but-not-running) → cycle
    # the compute so it re-reads the now-wired Lakebase role. `start` errors if
    # compute is ACTIVE, so a stop precedes it.
    if not su.endswith("RUNNING"):
        if su.endswith("STOPPED"):
            info(f"App state {state or '?'} — starting compute.")
            try:
                w.apps.start_and_wait(cfg.app_name)
            except DatabricksError as e:
                warn(f"start returned an error: {e}")
        else:
            info(f"App state {state or '?'} — cycling compute (stop→start).")
            try:
                w.apps.stop_and_wait(cfg.app_name)
            except DatabricksError as e:
                warn(f"stop returned an error: {e}")
            try:
                w.apps.start_and_wait(cfg.app_name)
            except DatabricksError as e:
                warn(f"start returned an error: {e}")
    for _ in range(60):
        state, url = _state_url(w, cfg.app_name)
        su = state.upper()
        if su.endswith("RUNNING") or su.endswith("CRASHED"):
            break
        time.sleep(8)
    if state.upper().endswith("RUNNING"):
        ok("App is RUNNING.")
    else:
        warn(f"App state is '{state or 'unknown'}'. Inspect logs with:")
        warn(f"    databricks apps logs {cfg.app_name}"
             + (f" --profile {cfg.profile}" if cfg.profile else ""))
    if url:
        print(f"\n{BOLD}{GREEN}App URL: {url}{RESET}")


# ── plan ────────────────────────────────────────────────────────────────────
def print_plan(cfg: Config) -> None:
    banner("Solution Builder — install plan (pure Python / notebook-native)")
    rows = [
        ("Workspace", cfg.workspace_url),
        ("Auth", f"profile: {cfg.profile}" if cfg.profile else "ambient/env auth"),
        ("Artifact", str(cfg.artifact_path)),
        ("App name", cfg.app_name),
        ("Default catalog", cfg.default_catalog),
        ("Lakebase", f"{cfg.lb_project} ({'reuse' if cfg.lb_reuse else 'create if missing'})"),
        ("LLM endpoint", cfg.ep_llm),
        ("AI Gateway", cfg.ep_gw),
        ("AI Gateway mini", cfg.ep_gw_mini),
        ("Embedding", cfg.ep_gw_emb),
        ("Deployer SP", f"{cfg.sp_name} (grant={cfg.sp_grant})" if cfg.sp_enabled
                        else "DISABLED — dashboards won't build"),
        ("Scopes", f"{len(ALL_SCOPES)} explicit (no all-apis)"),
        ("Install logging", "on" if cfg.log_enabled else "off"),
    ]
    for k, v in rows:
        print(f"  {BOLD}{k:<18}{RESET} {v}")


# ── public entrypoints ────────────────────────────────────────────────────────
def run(config_path: str | os.PathLike | None = None, dry_run: bool = False) -> None:
    """Programmatic entrypoint (use this from a notebook)."""
    cfg_path = Path(config_path or (Path(__file__).resolve().parent / "config.yaml")).resolve()
    if not cfg_path.exists():
        die(f"Config file not found: {cfg_path}")
    cfg = Config(load_yaml(cfg_path), cfg_path)
    cfg.validate()

    print_plan(cfg)
    if dry_run:
        print()
        ok("Dry run — nothing was changed.")
        return

    banner(f"Installing Solution Builder into {cfg.workspace_url}")
    w = make_client(cfg)
    user = step_auth(w, cfg)
    step_log_install(w, cfg, user)
    staged = step_stage_artifact(cfg)
    step_check_endpoints(w, cfg)
    lb = step_provision_lakebase(w, cfg)
    sp = step_deployer_sp(w, cfg)
    step_configure(staged, cfg, lb, sp)
    source_path = step_upload_source(w, cfg, staged, user)
    app = step_create_app(w, cfg)
    step_grant_sp(w, cfg, app, lb)      # wire SP↔Lakebase BEFORE deploy auto-starts the app
    step_deploy(w, cfg, source_path)
    step_launch(w, cfg)

    banner("🎉 Solution Builder is installed")
    hr()
    print(f"{BOLD}Next steps (manual — required):{RESET}")
    print("  1. Open the App URL above (a fresh/incognito window is most reliable).")
    print("  2. Accept the authorization/consent prompt so your token carries the new scopes.")
    print(f"     If no prompt appears: stop then start the app compute for '{cfg.app_name}'.")
    print("  3. On the home page, choose \"Describe your story\" and build your first solution.")
    print()
    info("Re-run any time — every step is idempotent and safe to repeat.")


def main() -> None:
    ap = argparse.ArgumentParser(
        description="Deterministic pure-Python Solution Builder installer. "
                    "All install values come from config.yaml.")
    ap.add_argument("--config", default=None,
                    help="Path to config.yaml (default: alongside this script).")
    ap.add_argument("--dry-run", action="store_true",
                    help="Print the resolved plan and exit without touching anything.")
    args = ap.parse_args()
    run(args.config, dry_run=args.dry_run)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        die("Interrupted.", code=130)
