"""AA-1185 (S297): offline guards for the NAT instance swap that runs before the weekly patch.

The first AWS-RunPatchBaseline run on the 512 MB NAT instance (27/11/2026) thrashed for 3 h 22 min with no swap and was
killed at the document's default 10,800 s step timeout. security_account_defaults.tf section 5 adds a Command document
and an association that make a persistent swapfile before the patch run, and gives the patch run an explicit timeout.

1. The swap association targets the NAT instance, runs at creation and every Sunday before the patch association, whose
   schedule, reboot option and target do not change; the patch run has an explicit step timeout.
2. The swap document is a schema 2.2 Command document with one Linux shell step and an explicit timeout.
3. The script (rendered like Terraform renders the heredoc) is idempotent and safe, run against stub commands: a first
   run makes and activates the file and adds one nofail fstab line; a second run changes nothing; a file that does not
   activate is rebuilt; too little disk fails without writing a file.
4. The apply role manages aa-ecosys-* documents only, and never gets ssm:SendCommand.
5. Nothing here touches the NAT instance itself (no user_data / instance type change in this section).

Run: python3 -m pytest -q tools/terraform/tests/test_aa1185_nat_swap.py
"""
import os
import re
import shutil
import stat
import subprocess
import textwrap
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[3]
AA365 = ROOT / "accounts" / "aa365"
DEFAULTS = (AA365 / "security_account_defaults.tf").read_text(encoding="utf-8")
SEC = (AA365 / "cicd_sec.tf").read_text(encoding="utf-8")


def _block(text: str, opener: str) -> str:
    m = re.search(rf"^{re.escape(opener)} \{{", text, re.M)
    assert m, f"{opener} not found"
    body = text[m.end():]
    return body[: re.search(r"^\}", body, re.M).start()]


def _locals() -> dict[str, str]:
    section = DEFAULTS[DEFAULTS.index("# ── 5. NAT instance swap"):]
    return dict(re.findall(r"^\s+(nat_\w+)\s+=\s+(\d+)", section, re.M))


def _statements(doc: str) -> dict[str, str]:
    out = {}
    for m in re.finditer(r'sid\s+=\s+"(\w+)"', doc):
        start = doc.rindex("statement {", 0, m.start())
        nxt = doc.find("statement {", m.end())
        out[m.group(1)] = doc[start: nxt if nxt != -1 else len(doc)]
    return out


def render_script() -> str:
    """The nat_swap_script heredoc as Terraform renders it (<<- strips the common indent, $${ is a literal ${)."""
    m = re.search(r"nat_swap_script = <<-EOT\n(.*?)\n\s*EOT\n", DEFAULTS, re.S)
    assert m, "nat_swap_script heredoc not found"
    body = textwrap.dedent(m.group(1))
    values = _locals()

    def sub(match: re.Match) -> str:
        return values[match.group(1)]

    body = re.sub(r"(?<!\$)\$\{local\.(\w+)\}", sub, body)
    assert "${local." not in body.replace("$${", ""), "unrendered Terraform reference left in the script"
    return body.replace("$${", "${") + "\n"


# ── 1. associations ──────────────────────────────────────────────────────────
def test_patch_association_keeps_schedule_and_gains_a_timeout():
    patch = _block(DEFAULTS, 'resource "aws_ssm_association" "nat_patch"')
    assert 'name             = "AWS-RunPatchBaseline"' in patch
    assert 'schedule_expression         = "cron(0 21 ? * SUN *)"' in patch
    assert "apply_only_at_cron_interval = true" in patch
    assert re.search(r'RebootOption\s+= "RebootIfNeeded"', patch)
    assert "StepTimeoutSeconds = tostring(local.nat_patch_timeout_seconds)" in patch
    assert "values = [module.vpc.nat_instance_id]" in patch
    timeout = int(_locals()["nat_patch_timeout_seconds"])
    assert 600 <= timeout < 10800, "explicit, and shorter than the document default that the first run hit"


def test_swap_association_runs_before_the_patch_and_at_creation():
    swap = _block(DEFAULTS, 'resource "aws_ssm_association" "nat_swap"')
    assert "name             = aws_ssm_document.nat_swap.name" in swap
    assert "values = [module.vpc.nat_instance_id]" in swap
    assert "apply_only_at_cron_interval = false" in swap, "a new NAT instance must get its swap at once"
    m = re.search(r'schedule_expression\s+= "cron\((\d+) (\d+) \? \* SUN \*\)"', swap)
    assert m, "the swap runs on Sunday, like the patch"
    minute, hour = int(m.group(1)), int(m.group(2))
    assert (hour, minute) < (21, 0) and (21 * 60) - (hour * 60 + minute) <= 60, "within the hour before 21:00 UTC"


# ── 2. document ──────────────────────────────────────────────────────────────
def test_swap_document_is_one_linux_shell_step_with_a_timeout():
    doc = _block(DEFAULTS, 'resource "aws_ssm_document" "nat_swap"')
    assert 'name            = "aa-ecosys-${var.environment}-nat-swap"' in doc
    assert 'document_type   = "Command"' in doc
    assert 'schemaVersion = "2.2"' in doc
    assert doc.count("action ") == 1 and 'action       = "aws:runShellScript"' in doc
    assert 'precondition = { StringEquals = ["platformType", "Linux"] }' in doc
    assert "timeoutSeconds = tostring(local.nat_swap_timeout_seconds)" in doc
    assert "runCommand     = split(\"\\n\", trimspace(local.nat_swap_script))" in doc
    assert "App = \"shared\", Component = \"network\"" in doc


# ── 3. script behaviour on stubs ─────────────────────────────────────────────
STUBS = {
    # Active swap list in $STATE/active; mkswap writes a signature the swapon stub requires.
    "swapon": """#!/bin/bash
if [ "$1" = "--show=NAME" ]; then cat "$STATE/active" 2>/dev/null; exit 0; fi
if [ "$1" = "--show" ]; then echo "NAME TYPE"; cat "$STATE/active" 2>/dev/null; exit 0; fi
grep -q SWAPSIGNATURE "$1" 2>/dev/null || { echo "swapon: $1: invalid" >&2; exit 255; }
echo "$1" >> "$STATE/active"
""",
    "mkswap": '#!/bin/bash\necho SWAPSIGNATURE > "$1"\necho mkswap >> "$STATE/calls"\n',
    "dd": '#!/bin/bash\nfor a in "$@"; do case $a in of=*) : > "${a#of=}";; esac; done\necho dd >> "$STATE/calls"\n',
    "df": '#!/bin/bash\necho "Avail"\necho " $AVAIL_MB"\n',
    "free": "#!/bin/bash\necho free\n",
}


@pytest.fixture()
def sandbox(tmp_path):
    bindir = tmp_path / "bin"
    bindir.mkdir()
    for name, body in STUBS.items():
        f = bindir / name
        f.write_text(body)
        f.chmod(f.stat().st_mode | stat.S_IEXEC)
    script = tmp_path / "swap.sh"
    script.write_text(render_script())
    state = tmp_path / "state"
    state.mkdir()
    fstab = tmp_path / "fstab"
    fstab.write_text("UUID=root / xfs defaults 0 0\n")
    swapfile = tmp_path / "swapfile"

    def run(avail_mb: int = 4000):
        env = {
            "PATH": f"{bindir}:{os.environ['PATH']}",
            "STATE": str(state),
            "SWAPFILE": str(swapfile),
            "FSTAB": str(fstab),
            "AVAIL_MB": str(avail_mb),
        }
        return subprocess.run(["bash", str(script)], env=env, capture_output=True, text=True, timeout=30)

    return run, swapfile, fstab, state


def _calls(state: Path) -> list[str]:
    f = state / "calls"
    return f.read_text().split() if f.exists() else []


@pytest.mark.skipif(shutil.which("bash") is None, reason="bash needed")
def test_first_run_creates_activates_and_adds_one_fstab_line(sandbox):
    run, swapfile, fstab, state = sandbox
    r = run()
    assert r.returncode == 0, r.stderr
    assert "created" in r.stdout and "fstab entry added" in r.stdout
    assert swapfile.exists() and not Path(f"{swapfile}.new").exists()
    assert oct(swapfile.stat().st_mode & 0o777) == "0o600"
    assert (state / "active").read_text().split() == [str(swapfile)]
    lines = [ln for ln in fstab.read_text().splitlines() if ln.startswith(str(swapfile))]
    assert lines == [f"{swapfile} none swap defaults,nofail 0 0"], "nofail: a missing file never blocks the NAT boot"


@pytest.mark.skipif(shutil.which("bash") is None, reason="bash needed")
def test_second_run_changes_nothing(sandbox):
    run, swapfile, fstab, state = sandbox
    assert run().returncode == 0
    before = (fstab.read_text(), _calls(state))
    r = run()
    assert r.returncode == 0, r.stderr
    assert "already active" in r.stdout and "fstab entry added" not in r.stdout
    assert (fstab.read_text(), _calls(state)) == before, "no second dd / mkswap / fstab line"


@pytest.mark.skipif(shutil.which("bash") is None, reason="bash needed")
def test_after_reboot_the_existing_file_is_activated_not_rebuilt(sandbox):
    run, swapfile, fstab, state = sandbox
    assert run().returncode == 0
    (state / "active").write_text("")  # swap not active (e.g. fstab not read yet)
    calls = _calls(state)
    r = run()
    assert r.returncode == 0, r.stderr
    assert _calls(state) == calls
    assert (state / "active").read_text().split() == [str(swapfile)]


@pytest.mark.skipif(shutil.which("bash") is None, reason="bash needed")
def test_a_file_that_does_not_activate_is_rebuilt(sandbox):
    run, swapfile, fstab, state = sandbox
    swapfile.write_text("half written\n")
    Path(f"{swapfile}.new").write_text("left by an interrupted run\n")
    r = run()
    assert r.returncode == 0, r.stderr
    assert "rebuilding" in r.stdout
    assert "SWAPSIGNATURE" in swapfile.read_text()
    assert not Path(f"{swapfile}.new").exists()


@pytest.mark.skipif(shutil.which("bash") is None, reason="bash needed")
def test_too_little_disk_fails_without_a_file(sandbox):
    run, swapfile, fstab, state = sandbox
    need = int(_locals()["nat_swap_size_mb"]) + int(_locals()["nat_swap_min_free_mb"])
    r = run(avail_mb=need - 1)
    assert r.returncode != 0
    assert "no swapfile made" in r.stderr
    assert not swapfile.exists() and not Path(f"{swapfile}.new").exists()
    assert str(swapfile) not in fstab.read_text()


# ── 4. IAM ───────────────────────────────────────────────────────────────────
def test_apply_role_manages_only_aa_ecosys_documents():
    stmts = _statements(_block(SEC, 'data "aws_iam_policy_document" "tf_apply_sec"'))
    doc = stmts["NatSwapDocument"]
    assert 'resources = ["arn:aws:ssm:${var.aws_region}:${var.account_id}:document/aa-ecosys-*"]' in doc
    for verb in ("ssm:CreateDocument", "ssm:UpdateDocument", "ssm:DeleteDocument", "ssm:DescribeDocumentPermission"):
        assert verb in doc
    assoc = stmts["NatPatchAssociation"]
    assert ":document/AWS-RunPatchBaseline" in assoc and ":document/aa-ecosys-*" in assoc
    assert ":document/*" not in SEC, "no wildcard over every document"
    for sid, body in stmts.items():
        for verb in ("ssm:SendCommand", "ssm:StartAssociationsOnce", "ssm:ModifyDocumentPermission"):
            assert f'"{verb}"' not in body, f"{sid} must not grant {verb}"


# ── 5. the NAT instance is not touched ───────────────────────────────────────
def test_section_does_not_change_the_instance():
    section = DEFAULTS[DEFAULTS.index("# ── 5. NAT instance swap"):]
    code = "\n".join(ln for ln in section.splitlines() if not ln.lstrip().startswith("#"))
    for word in ("aws_instance", "user_data", "instance_type"):
        assert word not in code
