#!/usr/bin/env python3
"""Workflow lint (S271 lessons guard G15): the repo-specific rules actionlint does not know.

Each rule comes from a CI incident written in the root lessons log:

  WL1 vars-sensitive   No `vars.<NAME>` whose name says ARN, ROLE, ACCOUNT_ID, SECRET, TOKEN, PASSWORD or KEY. A
                       variable is printed in clear in the run log, and this repo's logs are public; a role ARN
                       carries the account id (Scrub corpus workflow read vars.SCRUB_CORPUS_ROLE_ARN, S249). Use
                       `secrets.*`, which GitHub masks.
  WL2 playwright-pin   A job that runs Playwright pins `runs-on: ubuntu-24.04`: when ubuntu-latest moved to 26.04,
                       "Playwright does not support chromium on ubuntu26.04-x64" blocked a production promotion (S252,
                       S253).
  WL3 npm-ci-lockfile  A step that runs `npm ci` reads a package-lock.json that git tracks in its working directory:
                       a gitignored lockfile broke a workflow at its first run (S220).
  WL4 cache-default    A workflow saves caches only on the default branch (S273: GitHub keeps 10 GB of caches per
                       repo and evicts least-recently-used entries above it; pull request and merge-queue caches, which
                       only that ref can read, were 7.5 GB of AA-CIS-App's 10.7 GB). No `cache:` input on
                       actions/setup-python or actions/setup-node (they save on every ref) and `package-manager-cache:
                       false` on setup-node v5+; astral-sh/setup-uv sets `save-cache` to a default-branch test; no
                       combined actions/cache (restore with actions/cache/restore, save with actions/cache/save); every
                       actions/cache/save runs under `if:` with `github.ref == 'refs/heads/main'` (or master);
                       aquasecurity/trivy-action has `cache: "false"` (its DB cache saves on every ref).
  WL5 external-download  No step fetches a binary from outside without a cache and a sha256 pin (S273: GitHub throttled
                       unauthenticated release downloads and the actions that download their own binary failed CI with
                       HTTP 504): no action from DOWNLOADERS (anchore/sbom-action, setup-trivy, trivy-action without
                       `skip-setup-trivy: "true"`, lychee-action, ...), and a `run:` that fetches a release asset or an
                       archive (curl / wget / gh release download) needs an earlier actions/cache(/restore) step in
                       its job and a sha256 check. Use ./.github/actions/release-bin (or ./.github/actions/lychee).
                       Also checked in the composite actions under .github/actions (WL5 only: a composite action's
                       binary cache is keyed on its pin and may save on a miss).
  WL6 action-pin       Every `uses:` (a reusable-workflow job, a job step, a composite action step) names a full-length
                       commit SHA, `<owner>/<repo>[/<path>]@<40-hex sha> # vX.Y.Z`, the trailing comment keeping the
                       release tag for readers and Dependabot (which moves the SHA and the comment together). Whoever
                       controls an action's repository can move a tag; the org setting "Require actions to be pinned
                       to a full-length commit SHA" (root ADR 0021 decision 2.3) fails a run that names one (AA-1024,
                       S273). Exempt: a local `./` path and `docker://<image>@sha256:<digest>`. Also checked in the
                       composite actions; `--skip` does not turn it off (the org setting refuses a tag pin whatever
                       this script says).

The workflow `Workflow Lint` runs this next to a pinned actionlint. Stdlib + PyYAML.
Run: python3 -B .github/scripts/workflow_lint.py [--skip WL1[,WL2]] [WORKFLOW.yml ...]
     (default: every .github/workflows file, then every .github/actions/*/action.yml for WL5 and WL6)
Exit 0 = clean, 1 = findings (one line each: file:job:rule message), 2 = a workflow does not parse.

One file, the same in every repo (AA-CIS-Infra first, vendored into the root, AA-CIS-App, AA-Booking, AA-Partner and
AA-TripPlanner-Web by AA-1024, S272): change it in all of them in the same wave. `--skip` turns a rule off for a repo
that still has uses to move (Booking and Partner read vars.AWS_ROLE_ARN until it moves to a secret, a repo-settings
step for the tech lead); a shell comment inside a `run:` is never a use; a `working-directory` built from an expression
(a matrix of other repos' apps) cannot be checked statically and is listed as unchecked, not as a finding.
"""
from __future__ import annotations

import os
import re
import subprocess
import sys

import yaml

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
SENSITIVE_VAR = re.compile(
    r"\bvars\.([A-Za-z0-9_]*(?:ARN|ROLE|ACCOUNT_ID|SECRET|TOKEN|PASSWORD|PRIVATE_KEY|API_KEY|ACCESS_KEY)[A-Za-z0-9_]*)",
    re.I,
)
PLAYWRIGHT = re.compile(r"playwright", re.I)
NPM_CI = re.compile(r"(?:^|[;&|(]|\s)npm\s+ci\b", re.M)
PINNED_RUNNER = "ubuntu-24.04"
NESTED_EXPR = re.compile(r"\$\{\{(?:(?!\}\}).)*\$\{\{")
DEFAULT_REF = re.compile(r"github\.ref\s*==\s*'refs/heads/(?:main|master)'")
CACHE_INPUT_ACTIONS = ("actions/setup-python@", "actions/setup-node@")
# Actions that download a binary themselves on every run (no cache keyed on a sha256 pin): what to use instead.
DOWNLOADERS = {
    "anchore/sbom-action@": "run syft from ./.github/actions/release-bin (tool: syft)",
    "anchore/scan-action@": "run grype from ./.github/actions/release-bin",
    "aquasecurity/setup-trivy@": "install trivy with ./.github/actions/release-bin (tool: trivy)",
    "lycheeverse/lychee-action@": "use ./.github/actions/lychee",
    "gitleaks/gitleaks-action@": "run the pinned gitleaks image (ghcr.io/gitleaks/gitleaks:<version>)",
}
FETCH = re.compile(r"(?:^|[;&|(]|\s)(?:curl|wget|Invoke-WebRequest)\b|\bgh\s+release\s+download\b", re.M)
URL = re.compile(r"https?://[^\s\"'<>`)]+")
ARCHIVE = re.compile(r"\.(?:tar\.gz|tgz|tar\.xz|txz|tar\.bz2|zip|deb|rpm|whl|gz|xz|bz2|appimage|exe|msi|dmg|pkg)$"
                     r"|/install\.sh$|/releases/download/|/archive/refs/", re.I)
DOWNLOAD_HOSTS = ("raw.githubusercontent.com", "objects.githubusercontent.com", "release-assets.githubusercontent.com")
PIPE_TO_SHELL = re.compile(r"\|\s*(?:sudo\s+)?(?:ba)?sh\b")
SHA_CHECK = re.compile(r"sha256sum\s+(?:-c|--check)|shasum\s+-a\s*256\s+(?:-c|--check)|\b[0-9a-f]{64}\b")
SHA_PINNED = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_./-]+)?@[0-9a-f]{40}$")
DOCKER_DIGEST = re.compile(r"^docker://[^@\s]+@sha256:[0-9a-f]{64}$")
USES_LINE = re.compile(r"^\s*(?:-\s*)?uses:\s*['\"]?([^'\"\s#]+)['\"]?(.*)$")
TAG_COMMENT = re.compile(r"^\s+#\s*(v?\d+(?:\.\d+)*)\b")


def _strip_comments(text: str) -> str:
    return "\n".join(line for line in text.splitlines() if not line.lstrip().startswith("#"))


def _job_text(job: dict) -> str:
    """The job as text for the Playwright search, without the shell comments of its run: scripts."""
    steps = [{**s, "run": _strip_comments(str(s["run"]))} if isinstance(s, dict) and "run" in s else s
             for s in job.get("steps") or []]
    return yaml.safe_dump({**job, "steps": steps}, sort_keys=False)


def tracked(path: str, repo_root: str) -> bool:
    """True when git tracks the file (falls back to "exists" outside a git checkout)."""
    try:
        proc = subprocess.run(["git", "-C", repo_root, "ls-files", "--error-unmatch", path],
                              capture_output=True, text=True, timeout=30)
        if proc.returncode == 0:
            return True
        if "not a git repository" not in proc.stderr:
            return False
    except (OSError, subprocess.TimeoutExpired):
        pass
    return os.path.isfile(os.path.join(repo_root, path))


def _major(uses: str, tags: dict | None = None) -> int | None:
    """The major version of `owner/name@vN...`; for a SHA pin, of its `# vN...` comment, which YAML drops, so it comes
    from `tags` (`pin_tags` of the file text). None when neither says (WL4 then treats setup-node as v5+)."""
    tag = (tags or {}).get(uses, "")
    m = re.search(r"@v(\d+)", uses) or re.search(r"#\s*v(\d+)", uses) or re.match(r"v?(\d+)", tag)
    return int(m.group(1)) if m else None


def pin_tags(text: str) -> dict:
    """`{"owner/name@<sha>": "vX.Y.Z"}` from the `uses: ...@<sha> # vX.Y.Z` lines of a file (not shell comments)."""
    tags = {}
    for line in text.splitlines():
        m = None if line.lstrip().startswith("#") else USES_LINE.match(line)
        c = TAG_COMMENT.match(m.group(2)) if m else None
        if c:
            tags[m.group(1)] = c.group(1)
    return tags


def _uses(doc: dict) -> list[tuple[str, str]]:
    """(job id, ref) of every `uses:` of a workflow (a reusable-workflow job, a job step) or a composite action
    (its steps, job "-")."""
    refs = []
    for job_id, job in (doc.get("jobs") or {}).items():
        if isinstance(job, dict):
            refs += [(job_id, str(job["uses"]))] if job.get("uses") else []
            refs += [(job_id, str(s["uses"])) for s in job.get("steps") or [] if isinstance(s, dict) and s.get("uses")]
    runs = doc.get("runs") if isinstance(doc.get("runs"), dict) else {}
    refs += [("-", str(s["uses"])) for s in runs.get("steps") or [] if isinstance(s, dict) and s.get("uses")]
    return refs


def pin_findings(name: str, doc: dict, text: str) -> list[str]:
    """WL6: every action on a full-length commit SHA, its release tag in a trailing `# vX.Y.Z` comment."""
    findings = []
    for job_id, ref in _uses(doc):
        if ref.startswith("./") or DOCKER_DIGEST.match(ref) or SHA_PINNED.match(ref):
            continue
        fix = ("docker://<image>@sha256:<digest>" if ref.startswith("docker://") else
               "<owner>/<repo>@<40-hex sha> # vX.Y.Z (the tag's commit from gh api "
               "repos/<owner>/<repo>/git/ref/tags/<tag>, annotated tags dereferenced)")
        findings.append(f"{name}:{job_id}:WL6 {ref} is not pinned to a full-length commit SHA: use {fix}")
    for n, line in enumerate(text.splitlines(), 1):
        m = None if line.lstrip().startswith("#") else USES_LINE.match(line)
        if m and SHA_PINNED.match(m.group(1)) and not TAG_COMMENT.match(m.group(2)):
            findings.append(f"{name}:-:WL6 line {n}: keep the release tag of {m.group(1)} in a trailing comment "
                            "(# vX.Y.Z)")
    return findings


def _is_download_url(url: str) -> bool:
    host = url.split("://", 1)[1].split("/", 1)[0].lower()
    if host.split(":")[0] in ("localhost", "127.0.0.1", "0.0.0.0") or "${" in host or "$" in host[:1]:
        return False
    path = url.split("?", 1)[0].split("#", 1)[0]
    return host in DOWNLOAD_HOSTS or bool(ARCHIVE.search(path))


def _downloads(run: str) -> list[str]:
    """What a run script fetches from outside: download-shaped URLs (or `gh release download`), when it fetches."""
    if not FETCH.search(run):
        return []
    got = [u for u in URL.findall(run) if _is_download_url(u)]
    if not got and (re.search(r"\bgh\s+release\s+download\b", run) or
                    (PIPE_TO_SHELL.search(run) and URL.search(run))):
        got = [m.group(0) for m in re.finditer(r"gh\s+release\s+download\S*", run)] or URL.findall(run)[:1]
    return got


def _env_used(run: str, *envs) -> str:
    """The values of the env entries (workflow, job, step) that the run script names ($X, ${X} or env.X)."""
    vals = []
    for env in envs:
        for name, value in (env or {}).items() if isinstance(env, dict) else ():
            if re.search(rf"\$\{{?{re.escape(str(name))}\b|\benv\.{re.escape(str(name))}\b", run):
                vals.append(str(value))
    return " ".join(vals)


def _download_findings(where: str, steps: list, *envs) -> list[str]:
    """WL5 for one job's (or composite action's) steps."""
    findings, cached = [], False
    for step in steps or []:
        if not isinstance(step, dict):
            continue
        uses = str(step.get("uses") or "")
        with_ = step.get("with") or {}
        for prefix, fix in DOWNLOADERS.items():
            if uses.startswith(prefix):
                findings.append(f"{where}:WL5 {prefix[:-1]} downloads its binary on every run: {fix}")
        if uses.startswith("aquasecurity/trivy-action@") and str(with_.get("skip-setup-trivy")).lower() != "true":
            findings.append(f"{where}:WL5 aquasecurity/trivy-action installs trivy through setup-trivy: install it with "
                            "./.github/actions/release-bin (tool: trivy) and set skip-setup-trivy: \"true\"")
        if uses.startswith(("actions/cache@", "actions/cache/restore@")):
            cached = True
        run = _strip_comments(str(step.get("run") or ""))
        got = _downloads(run)
        if got:
            pinned = bool(SHA_CHECK.search(run + " " + _env_used(run, *envs, step.get("env"))))
            if not (cached and pinned):
                missing = " and ".join(x for x, ok in (("no cache", cached), ("no sha256 check", pinned)) if not ok)
                findings.append(f"{where}:WL5 step {step.get('name') or step.get('id') or '?'!r} downloads {got[0]} "
                                f"({missing}): use ./.github/actions/release-bin")
    return findings


def _cache_findings(where: str, steps: list, tags: dict | None = None) -> list[str]:
    """WL4 for one job's steps (`tags`: the release tags of the file's SHA pins, `pin_tags`)."""
    findings = []
    for step in steps or []:
        if not isinstance(step, dict):
            continue
        uses = str(step.get("uses") or "")
        with_ = step.get("with") or {}
        label = step.get("name") or step.get("id") or uses.split("@")[0]
        if uses.startswith(CACHE_INPUT_ACTIONS) and str(with_.get("cache") or "").strip():
            findings.append(f"{where}:WL4 {label!r}: no `cache:` on {uses.split('@')[0]} (it saves on every ref): "
                            "actions/cache/restore, and actions/cache/save only on the default branch")
        if uses.startswith("actions/setup-node@") and (_major(uses, tags) or 99) >= 5 \
                and str(with_.get("package-manager-cache")).lower() != "false":
            findings.append(f"{where}:WL4 {label!r}: setup-node v5+ needs package-manager-cache: false "
                            "(its automatic cache saves on every ref)")
        if uses.startswith("astral-sh/setup-uv@") and str(with_.get("enable-cache")).lower() != "false" \
                and not DEFAULT_REF.search(str(with_.get("save-cache") or "")):
            findings.append(f"{where}:WL4 {label!r}: setup-uv needs save-cache: ${{{{ github.ref == "
                            "'refs/heads/main' }} (restore on every ref, save on the default branch)")
        if uses.startswith("actions/cache@"):
            findings.append(f"{where}:WL4 {label!r}: actions/cache saves on every ref: actions/cache/restore, and "
                            "actions/cache/save under if: github.ref == 'refs/heads/main'")
        if uses.startswith("actions/cache/save@") and not DEFAULT_REF.search(str(step.get("if") or "")):
            findings.append(f"{where}:WL4 {label!r}: actions/cache/save needs if: github.ref == 'refs/heads/main' "
                            "(a pull request or merge-queue copy is readable only by that ref)")
        if uses.startswith(("actions/cache", "actions/setup-")) and any(
                NESTED_EXPR.search(str(v)) for v in with_.values()):
            findings.append(f"{where}:WL4 {label!r}: a `${{{{` inside an expression is a literal string (the key never "
                            "matches): use format('...{0}...', value)")
        if uses.startswith("aquasecurity/trivy-action@") and str(with_.get("cache")).lower() != "false":
            findings.append(f"{where}:WL4 {label!r}: trivy-action needs cache: \"false\" (its DB cache saves on every "
                            "ref): restore the DB with actions/cache/restore, save it on the default branch")
    return findings


RULES = ("WL1", "WL2", "WL3", "WL4", "WL5")   # the rules `--skip` accepts; WL6 always runs
UNCHECKED: list[str] = []   # npm ci steps whose working-directory is an expression (printed in the summary)


def lint_workflow(name: str, text: str, repo_root: str = REPO_ROOT, skip: frozenset = frozenset()) -> list[str]:
    wf = yaml.safe_load(text) or {}
    findings, tags = pin_findings(name, wf, text), pin_tags(text)
    for m in ([] if "WL1" in skip else SENSITIVE_VAR.finditer(_strip_comments(text))):
        findings.append(f"{name}:-:WL1 vars.{m.group(1)} looks sensitive (ARN / role / key): use secrets.{m.group(1)}"
                        " (variables are printed in clear in the public run log)")
    for job_id, job in (wf.get("jobs") or {}).items():
        if not isinstance(job, dict):
            continue
        body = _job_text({k: v for k, v in job.items() if k != "name"})
        runs_on = job.get("runs-on")
        if "WL2" not in skip and PLAYWRIGHT.search(body) and runs_on != PINNED_RUNNER:
            findings.append(f"{name}:{job_id}:WL2 a Playwright job must pin runs-on: {PINNED_RUNNER} (got {runs_on!r})")
        if "WL4" not in skip:
            findings += _cache_findings(f"{name}:{job_id}", job.get("steps"), tags)
        if "WL5" not in skip:
            findings += _download_findings(f"{name}:{job_id}", job.get("steps"), wf.get("env"), job.get("env"))
        default_dir = ((job.get("defaults") or {}).get("run") or {}).get("working-directory") or "."
        for step in job.get("steps") or []:
            run = _strip_comments(str(step.get("run") or ""))
            if "WL3" in skip or not NPM_CI.search(run):
                continue
            wd = str(step.get("working-directory") or default_dir)
            if "${{" in wd:
                UNCHECKED.append(f"{name}:{job_id}: npm ci in {wd}")
                continue
            lock = os.path.normpath(os.path.join(wd, "package-lock.json")).replace(os.sep, "/")
            if not tracked(lock, repo_root):
                findings.append(f"{name}:{job_id}:WL3 npm ci needs a git-tracked {lock}")
    return findings


def lint_action(name: str, text: str, skip: frozenset = frozenset()) -> list[str]:
    """WL5 and WL6 for a composite action (.github/actions/<name>/action.yml)."""
    action = yaml.safe_load(text) or {}
    runs = action.get("runs") or {}
    if runs.get("using") != "composite":
        return []
    findings = pin_findings(name, action, text)
    return findings + ([] if "WL5" in skip else _download_findings(f"{name}:-", runs.get("steps")))


def _action_files() -> list[str]:
    root = os.path.join(REPO_ROOT, ".github", "actions")
    if not os.path.isdir(root):
        return []
    return [os.path.join(root, d, f) for d in sorted(os.listdir(root)) for f in ("action.yml", "action.yaml")
            if os.path.isfile(os.path.join(root, d, f))]


def main(argv: list[str]) -> int:
    argv, skip = list(argv), set()
    while argv and argv[0] == "--skip":
        if len(argv) < 2 or not set(argv[1].split(",")) <= set(RULES):
            print(f"--skip needs rule ids from {', '.join(RULES)}", file=sys.stderr)
            return 2
        skip |= set(argv[1].split(","))
        argv = argv[2:]
    wf_dir = os.path.join(REPO_ROOT, ".github", "workflows")
    paths = argv or [os.path.join(wf_dir, n) for n in sorted(os.listdir(wf_dir)) if n.endswith((".yml", ".yaml"))]
    actions = [] if argv else _action_files()
    findings = []
    UNCHECKED.clear()
    for path in paths + actions:
        try:
            with open(path, encoding="utf-8") as fh:
                text = fh.read()
            if path in actions:
                findings += lint_action(os.path.relpath(path, REPO_ROOT), text, frozenset(skip))
            else:
                findings += lint_workflow(os.path.basename(path), text, skip=frozenset(skip))
        except (OSError, yaml.YAMLError) as exc:
            print(f"{path}: cannot read: {exc}", file=sys.stderr)
            return 2
    for f in findings:
        print(f)
    for u in UNCHECKED:
        print(f"unchecked (expression working-directory): {u}")
    skipped = f", skipped {','.join(sorted(skip))}" if skip else ""
    print(f"workflow_lint: {len(paths)} workflows, {len(actions)} composite actions, {len(findings)} findings{skipped}")
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
