"""tools/identity/crm_dev_identity.py (AA-935): DRY RUN by default, account guard, lookups by name, SUPPRESS on create,
idempotent re-runs, secrets never printed, the user list in step with the SES receipt rule. No AWS access: fakes."""

from __future__ import annotations

import json
import re
from pathlib import Path

import pytest

import crm_dev_identity as tool

REPO = Path(__file__).resolve().parents[3]
CLIENT_SECRET = "CLIENT-SECRET-VALUE-do-not-print"


class NotFound(Exception):
    pass


class FakeIdp:
    def __init__(self, existing: dict[str, str] | None = None) -> None:
        self.users = dict(existing or {})  # email -> sub
        self.created: list[dict] = []

    def list_user_pools(self, **kw):
        if "NextToken" not in kw:
            return {"UserPools": [{"Name": "aa-workforce-dev", "Id": "w"}], "NextToken": "p2"}
        return {"UserPools": [{"Name": "aa-external-dev", "Id": "pool-ext"}, {"Name": "aa-partner-dev", "Id": "pool-par"}]}

    def list_user_pool_clients(self, **kw):
        if kw["UserPoolId"] == "pool-par":
            return {"UserPoolClients": [{"ClientName": "aa-partner-dev-partner-web", "ClientId": "pcid"}]}
        return {"UserPoolClients": [{"ClientName": "aa-external-dev-cis-portal", "ClientId": "cid"}]}

    def describe_user_pool_client(self, **kw):
        assert kw in ({"UserPoolId": "pool-ext", "ClientId": "cid"}, {"UserPoolId": "pool-par", "ClientId": "pcid"})
        return {"UserPoolClient": {"ClientSecret": CLIENT_SECRET}}

    def list_users(self, UserPoolId, Filter, Limit):  # noqa: N803 — boto3 names
        email = re.match(r'email = "(.+)"', Filter).group(1)
        sub = self.users.get(email)
        return {"Users": [{"Attributes": [{"Name": "sub", "Value": sub}]}] if sub else []}

    def admin_create_user(self, **kw):
        self.created.append(kw)
        sub = f"sub-{len(self.users) + 1}"
        self.users[kw["Username"]] = sub
        return {"User": {"Attributes": [{"Name": "sub", "Value": sub}]}}


class FakePartnerIdp(FakeIdp):
    """The partner pool's first sign-in: NEW_PASSWORD_REQUIRED, then MFA_SETUP with a TOTP enrolment."""

    TOTP_SECRET = "JBSWY3DPEHPK3PXPJBSWY3DPEHPK3PXP"

    def __init__(self, existing: dict[str, str] | None = None) -> None:
        super().__init__(existing)
        self.auth: list[tuple[str, dict]] = []
        self.deleted: list[str] = []

    def initiate_auth(self, **kw):
        self.auth.append(("initiate_auth", kw))
        assert kw["AuthFlow"] == "USER_AUTH" and kw["AuthParameters"]["PREFERRED_CHALLENGE"] == "PASSWORD"
        return {"ChallengeName": "NEW_PASSWORD_REQUIRED", "Session": "s1"}

    def respond_to_auth_challenge(self, **kw):
        self.auth.append((kw["ChallengeName"], kw))
        if kw["ChallengeName"] == "NEW_PASSWORD_REQUIRED":
            return {"ChallengeName": "MFA_SETUP", "Session": "s2"}
        return {"AuthenticationResult": {"AccessToken": "x"}}

    def associate_software_token(self, **kw):
        self.auth.append(("associate_software_token", kw))
        return {"SecretCode": self.TOTP_SECRET, "Session": "s3"}

    def verify_software_token(self, **kw):
        self.auth.append(("verify_software_token", kw))
        assert kw["UserCode"] == tool.totp(self.TOTP_SECRET)
        return {"Status": "SUCCESS", "Session": "s4"}

    def admin_delete_user(self, **kw):
        self.deleted.append(kw["Username"])


class FakeSm:
    class exceptions:  # noqa: N801 — boto3 shape
        ResourceNotFoundException = NotFound

    def __init__(self, values: dict[str, str] | None = None) -> None:
        self.values = dict(values or {})
        self.writes: list[tuple[str, str]] = []

    def describe_secret(self, SecretId):  # noqa: N803
        if SecretId not in self.values:
            raise NotFound(SecretId)
        return {"Name": SecretId}

    def get_secret_value(self, SecretId):  # noqa: N803
        if SecretId not in self.values or self.values[SecretId] is None:
            raise NotFound(SecretId)
        return {"SecretString": self.values[SecretId]}

    def put_secret_value(self, SecretId, SecretString):  # noqa: N803
        self.values[SecretId] = SecretString
        self.writes.append((SecretId, SecretString))
        return {"VersionId": "v1"}

    def create_secret(self, Name, Description, SecretString, Tags):  # noqa: N803
        self.values[Name] = SecretString
        self.writes.append((Name, SecretString))
        return {"VersionId": "v0"}


class FakeSts:
    def __init__(self, account: str = tool.DEFAULT_ACCOUNT) -> None:
        self.account = account

    def get_caller_identity(self):
        return {"Account": self.account}


def run(argv, idp=None, sm=None, sts=None):
    return tool.main(["--profile", "", *argv], (sts or FakeSts(), idp or FakeIdp(), sm or FakeSm()))


def lines(capsys) -> list[dict]:
    return [json.loads(x) for x in capsys.readouterr().out.splitlines()]


def test_user_list_matches_the_seeder_catalogue_and_the_receipt_rule():
    users = tool.load_users()
    assert {(u.agency, u.role) for u in users} >= {("sen-vang", "owner"), ("southern-cross", "owner")}
    assert all(u.role in tool.ROLES for u in users)
    mailbox = (REPO / "accounts" / "aa365" / "e2e_mailbox.tf").read_text(encoding="utf-8")
    assert "tools/identity/crm_e2e_users.json" in mailbox
    assert 'e2e-test-crm-${u.agency}-${u.role}@${local.e2e_mail_domain}' in mailbox
    assert users[0].email("example.test") == "e2e-test-crm-sen-vang-owner@e2e-mail.example.test"


def test_dry_run_writes_nothing(capsys):
    idp, sm = FakeIdp(), FakeSm()
    assert run(["e2e-users", "--write-secrets"], idp, sm) == 0
    rows = lines(capsys)
    assert {r.get("action") for r in rows[:-1]} == {"would_create"}
    assert rows[-1]["summary"] == "dry_run" and rows[-1]["created"] == 0
    assert idp.created == [] and sm.writes == []


def test_apply_creates_with_suppress_then_is_idempotent(capsys):
    idp, sm = FakeIdp(), FakeSm()
    assert run(["e2e-users", "--apply", "--write-secrets"], idp, sm) == 0
    rows = lines(capsys)
    assert all(c["MessageAction"] == "SUPPRESS" for c in idp.created)
    assert all("TemporaryPassword" not in c for c in idp.created)
    assert {a["Name"]: a["Value"] for a in idp.created[0]["UserAttributes"]}["email_verified"] == "true"
    assert rows[0]["member"] == f"sen-vang:owner:{rows[0]['sub']}"
    assert rows[-1]["seeder"].startswith("python -m app.seed --apply --member sen-vang:owner:")
    stored = json.loads(sm.values["crm/dev/e2e-test-crm/sen-vang-owner"])
    assert stored == {"email": rows[0]["email"], "sub": rows[0]["sub"], "agency": "sen-vang", "role": "owner", "pool": "external"}
    assert "password" not in json.dumps(stored)
    created = len(idp.created)
    assert run(["e2e-users", "--apply"], idp, sm) == 0
    again = lines(capsys)
    assert {r["action"] for r in again[:-1]} == {"exists"} and len(idp.created) == created


def test_account_guard_refuses_another_account(capsys):
    assert run(["e2e-users"], sts=FakeSts("111111111111")) == 1
    assert "refused" in capsys.readouterr().err


def test_web_secret_keeps_the_session_secret_and_never_prints_values(capsys):
    sm = FakeSm({"crm/dev/web": None})
    assert run(["web-secret"], sm=sm) == 0
    first = lines(capsys)[0]
    assert first["action"] == "would_write" and set(first["changed"]) == {"session_secret", "cognito_client_secret"}
    assert sm.writes == []
    assert run(["web-secret", "--apply"], sm=sm) == 0
    out = capsys.readouterr().out
    assert CLIENT_SECRET not in out
    value = json.loads(sm.values["crm/dev/web"])
    assert value["cognito_client_secret"] == CLIENT_SECRET and len(value["session_secret"]) >= 32
    assert value["session_secret"] not in out
    assert run(["web-secret", "--apply"], sm=sm) == 0
    assert lines(capsys)[0]["action"] == "unchanged"
    kept = value["session_secret"]
    assert run(["web-secret", "--apply", "--rotate-session"], sm=sm) == 0
    capsys.readouterr()
    assert json.loads(sm.values["crm/dev/web"])["session_secret"] != kept


def test_web_secret_needs_the_terraform_shell(capsys):
    assert run(["web-secret", "--apply"], sm=FakeSm()) == 1
    assert "crm_web.tf" in capsys.readouterr().err


def test_bad_user_file_is_refused(tmp_path):
    bad = tmp_path / "u.json"
    bad.write_text(json.dumps({"users": [{"agency": "x", "role": "admin"}]}))
    with pytest.raises(tool.ToolError):
        tool.load_users(bad)
    dup = tmp_path / "d.json"
    dup.write_text(json.dumps({"users": [{"agency": "x", "role": "owner"}, {"agency": "x", "role": "owner"}]}))
    with pytest.raises(tool.ToolError):
        tool.load_users(dup)


def test_partner_apply_creates_enrols_and_stores_the_credentials(capsys):
    idp, sm = FakePartnerIdp(), FakeSm()
    assert run(["--pool", "partner", "e2e-users", "--apply", "--write-secrets"], idp, sm) == 0
    rows = lines(capsys)
    created = [r for r in rows[:-1]]
    assert {r["action"] for r in created} == {"created_enrolled"}
    assert all(c["MessageAction"] == "SUPPRESS" and len(c["TemporaryPassword"]) >= 14 for c in idp.created)
    # The invitee address is never created here.
    assert not any("harbour-lights-assistant" in c["Username"] for c in idp.created)
    stored = json.loads(sm.values["crm/dev/e2e-test-crm/sen-vang-owner"])
    assert stored["pool"] == "partner" and stored["totp_secret"] == FakePartnerIdp.TOTP_SECRET
    assert len(stored["password"]) >= 14 and stored["password"] != idp.created[0]["TemporaryPassword"]
    out = capsys.readouterr().out
    assert stored["password"] not in out and FakePartnerIdp.TOTP_SECRET not in out and CLIENT_SECRET not in out
    secret_hash = idp.auth[0][1]["AuthParameters"]["SECRET_HASH"]
    assert secret_hash == tool.secret_hash(stored["email"], "pcid", CLIENT_SECRET)
    # A re-run keeps the stored credentials of existing users.
    writes = len(sm.writes)
    assert run(["--pool", "partner", "e2e-users", "--apply", "--write-secrets"], idp, sm) == 0
    again = lines(capsys)
    assert {r["action"] for r in again[:-1]} == {"exists"} and len(sm.writes) == writes
    assert {r["secret"]["action"] for r in again[:-1]} == {"kept"}


def test_partner_apply_without_write_secrets_is_refused(capsys):
    assert run(["--pool", "partner", "e2e-users", "--apply"], FakePartnerIdp(), FakeSm()) == 1
    assert "--write-secrets" in capsys.readouterr().err


def test_invitee_reset_deletes_only_the_invitee(capsys):
    zone_email = "e2e-test-crm-harbour-lights-assistant@e2e-mail.lumiguides.it.com"
    idp = FakePartnerIdp({zone_email: "sub-inv", "e2e-test-crm-sen-vang-owner@e2e-mail.lumiguides.it.com": "sub-o"})
    assert run(["--pool", "partner", "invitee-reset"], idp) == 0
    assert lines(capsys) == [{"email": zone_email, "action": "would_delete"}] and idp.deleted == []
    assert run(["--pool", "partner", "invitee-reset", "--apply"], idp) == 0
    assert lines(capsys) == [{"email": zone_email, "action": "deleted"}] and idp.deleted == ["sub-inv"]
    assert run(["invitee-reset"], idp) == 1
    assert "partner" in capsys.readouterr().err


def test_web_secret_for_the_partner_client(capsys):
    sm = FakeSm({"crm/dev/web": None})
    assert run(["--pool", "partner", "web-secret", "--apply"], FakePartnerIdp(), sm) == 0
    assert lines(capsys)[0]["client"] == "aa-partner-dev-partner-web"
    assert json.loads(sm.values["crm/dev/web"])["cognito_client_secret"] == CLIENT_SECRET


def test_totp_matches_rfc_6238():
    # RFC 6238 appendix B, SHA-1 secret "12345678901234567890", T = 59 s -> 94287082 (last 6 digits).
    assert tool.totp("GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ", at=59) == "287082"
    password = tool.random_password()
    assert len(password) == 28 and any(c in tool.PASSWORD_SYMBOLS for c in password)


def test_invitee_entries_are_mailbox_recipients():
    users = tool.load_users()
    invitees = [u for u in users if u.invitee]
    assert [(u.agency, u.role) for u in invitees] == [("harbour-lights", "assistant")]


# ── AA-979: Content studio invitees (phase 2 re-enrolment E2E) ───────────────────────────────────

STUDIO_VIEWER = "e2e-test-studio-viewer@e2e-mail.lumiguides.it.com"
STUDIO_EDITOR = "e2e-test-studio-editor@e2e-mail.lumiguides.it.com"
CRM_INVITEE = "e2e-test-crm-harbour-lights-assistant@e2e-mail.lumiguides.it.com"


def test_studio_invitees_are_viewer_and_editor_and_mailbox_recipients():
    invitees = tool.load_studio_invitees()
    assert [u.role for u in invitees] == ["viewer", "editor"]
    assert [u.email("lumiguides.it.com") for u in invitees] == [STUDIO_VIEWER, STUDIO_EDITOR]
    mailbox = (REPO / "accounts" / "aa365" / "e2e_mailbox.tf").read_text(encoding="utf-8")
    assert 'for u in local.e2e_crm_file.studio_invitees : "e2e-test-studio-${u.role}@${local.e2e_mail_domain}"' in mailbox
    # The recipients reach the e2e-cognito rule (prefix inbound/), never the A10b admin rule.
    rule = re.search(r'resource "aws_ses_receipt_rule" "e2e_cognito" \{.*?\n\}', mailbox, re.S).group(0)
    assert "local.e2e_studio_invitee_recipients" in rule
    admin_rule = re.search(r'resource "aws_ses_receipt_rule" "e2e_cognito_admin" \{.*?\n\}', mailbox, re.S)
    assert admin_rule is None or "studio" not in admin_rule.group(0)


def test_studio_invitees_never_collide_with_the_crm_users():
    zone = "lumiguides.it.com"
    crm = {u.email(zone) for u in tool.load_users()}
    studio = {u.email(zone) for u in tool.load_studio_invitees()}
    assert not crm & studio


@pytest.mark.parametrize("entries", [[{"role": "owner"}], [{"role": "viewer"}, {"role": "viewer"}], [{"role": "Viewer"}]])
def test_bad_studio_invitees_are_refused(tmp_path, entries):
    bad = tmp_path / "users.json"
    bad.write_text(json.dumps({"users": [], "studio_invitees": entries}))
    with pytest.raises(tool.ToolError):
        tool.load_studio_invitees(bad)


def test_a_file_without_studio_invitees_has_none(tmp_path):
    plain = tmp_path / "users.json"
    plain.write_text(json.dumps({"users": [{"agency": "x", "role": "owner"}]}))
    assert tool.load_studio_invitees(plain) == []


def test_e2e_users_never_creates_a_studio_invitee(capsys):
    idp, sm = FakePartnerIdp(), FakeSm()
    assert run(["--pool", "partner", "e2e-users", "--apply", "--write-secrets"], idp, sm) == 0
    capsys.readouterr()
    assert not any("e2e-test-studio-" in c["Username"] for c in idp.created)


@pytest.mark.parametrize("target,email", [("studio-viewer", STUDIO_VIEWER), ("studio-editor", STUDIO_EDITOR)])
def test_invitee_reset_of_one_studio_role_deletes_only_that_one(capsys, target, email):
    idp = FakePartnerIdp({STUDIO_VIEWER: "sub-v", STUDIO_EDITOR: "sub-e", CRM_INVITEE: "sub-inv"})
    assert run(["--pool", "partner", "invitee-reset", "--invitee", target], idp) == 0
    assert lines(capsys) == [{"email": email, "action": "would_delete"}] and idp.deleted == []
    assert run(["--pool", "partner", "invitee-reset", "--invitee", target, "--apply"], idp) == 0
    assert lines(capsys) == [{"email": email, "action": "deleted"}]
    assert idp.deleted == [{"studio-viewer": "sub-v", "studio-editor": "sub-e"}[target]]


def test_invitee_reset_default_is_still_the_crm_invitee_only(capsys):
    idp = FakePartnerIdp({STUDIO_VIEWER: "sub-v", CRM_INVITEE: "sub-inv"})
    assert run(["--pool", "partner", "invitee-reset", "--apply"], idp) == 0
    assert lines(capsys) == [{"email": CRM_INVITEE, "action": "deleted"}] and idp.deleted == ["sub-inv"]


def test_invitee_reset_of_an_absent_studio_invitee(capsys):
    assert run(["--pool", "partner", "invitee-reset", "--invitee", "studio-editor", "--apply"], FakePartnerIdp()) == 0
    assert lines(capsys) == [{"email": STUDIO_EDITOR, "action": "absent"}]


def test_invitee_reset_refuses_an_unknown_target(capsys):
    with pytest.raises(SystemExit):
        run(["--pool", "partner", "invitee-reset", "--invitee", "studio-owner"], FakePartnerIdp())
    capsys.readouterr()


# ── AA-1019: the staff console's secret keys and the Dev-only staff E2E user (root ADR 0006a A10c) ──────────────────
STAFF_SECRET = "STAFF-CLIENT-SECRET-do-not-print"


class FakeWorkforceIdp(FakeIdp):
    """The WORKFORCE pool ("w") with its crm-staff client and group calls."""

    def __init__(self, existing: dict[str, str] | None = None, groups: set[str] | None = None) -> None:
        super().__init__(existing)
        self.groups = set(groups or ())
        self.added: list[str] = []

    def list_user_pool_clients(self, **kw):
        if kw["UserPoolId"] == "w":
            return {"UserPoolClients": [{"ClientName": "aa-workforce-dev-crm-staff", "ClientId": "scid"}]}
        return super().list_user_pool_clients(**kw)

    def describe_user_pool_client(self, **kw):
        if kw == {"UserPoolId": "w", "ClientId": "scid"}:
            return {"UserPoolClient": {"ClientSecret": STAFF_SECRET}}
        return super().describe_user_pool_client(**kw)

    def admin_list_groups_for_user(self, UserPoolId, Username):  # noqa: N803
        assert UserPoolId == "w"
        return {"Groups": [{"GroupName": g} for g in sorted(self.groups)]}

    def admin_add_user_to_group(self, UserPoolId, Username, GroupName):  # noqa: N803
        assert UserPoolId == "w"
        self.groups.add(GroupName)
        self.added.append(GroupName)


def test_staff_web_secret_adds_two_keys_and_keeps_the_agency_ones(capsys):
    agency = {"cognito_client_secret": "agency-cs", "session_secret": "a" * 40}
    sm = FakeSm({"crm/dev/web": json.dumps(agency)})
    idp = FakeWorkforceIdp()
    assert run(["staff-web-secret"], idp, sm) == 0
    dry = lines(capsys)[0]
    assert dry["action"] == "would_write" and set(dry["changed"]) == {"staff_session_secret", "staff_cognito_client_secret"}
    assert dry["client"] == "aa-workforce-dev-crm-staff" and sm.writes == []
    assert run(["staff-web-secret", "--apply"], idp, sm) == 0
    out = capsys.readouterr().out
    value = json.loads(sm.values["crm/dev/web"])
    assert {k: value[k] for k in agency} == agency
    assert value["staff_cognito_client_secret"] == STAFF_SECRET and len(value["staff_session_secret"]) >= 32
    assert value["staff_session_secret"] != value["session_secret"]
    assert STAFF_SECRET not in out and value["staff_session_secret"] not in out
    assert run(["staff-web-secret", "--apply"], idp, sm) == 0
    assert lines(capsys)[0]["action"] == "unchanged"
    kept = value["staff_session_secret"]
    assert run(["staff-web-secret", "--apply", "--rotate-staff-session"], idp, sm) == 0
    capsys.readouterr()
    assert json.loads(sm.values["crm/dev/web"])["staff_session_secret"] != kept


def test_the_agency_web_secret_keeps_the_staff_keys(capsys):
    staff = {"staff_cognito_client_secret": "s-cs", "staff_session_secret": "t" * 40}
    sm = FakeSm({"crm/dev/web": json.dumps({"cognito_client_secret": "old", "session_secret": "a" * 40, **staff})})
    assert run(["web-secret", "--apply"], sm=sm) == 0
    capsys.readouterr()
    value = json.loads(sm.values["crm/dev/web"])
    assert {k: value[k] for k in staff} == staff and value["cognito_client_secret"] == CLIENT_SECRET


def test_e2e_staff_creates_with_suppress_and_exactly_ops_and_support(capsys):
    idp = FakeWorkforceIdp()
    assert run(["e2e-staff"], idp) == 0
    dry = lines(capsys)[0]
    assert dry == {"email": "e2e-crm-staff@e2e-mail.lumiguides.it.com", "action": "would_create",
                   "groups": ["crm-ops", "crm-support"], "sub": None}
    assert idp.created == [] and idp.added == []
    assert run(["e2e-staff", "--apply"], idp) == 0
    row = lines(capsys)[0]
    [created] = idp.created
    assert created["UserPoolId"] == "w" and created["MessageAction"] == "SUPPRESS" and "TemporaryPassword" not in created
    assert {a["Name"]: a["Value"] for a in created["UserAttributes"]}["email_verified"] == "true"
    assert row["action"] == "created" and row["groups_added"] == ["crm-ops", "crm-support"] and row["sub"]
    assert run(["e2e-staff", "--apply"], idp) == 0
    again = lines(capsys)[0]
    assert again["action"] == "exists" and again["groups_added"] == [] and len(idp.created) == 1


def test_e2e_staff_matches_the_trigger_and_the_mailbox_rule():
    workforce = (REPO / "accounts" / "aa365" / "lambda_src" / "identity_triggers" / "workforce.py").read_text()
    assert f'E2E_CRM_STAFF_TEST_STAFF_EMAIL = "{tool.E2E_STAFF_LOCAL}@e2e-mail.lumiguides.it.com"' in workforce
    groups = ", ".join(f'"{g}"' for g in tool.E2E_STAFF_GROUPS)
    assert f"E2E_CRM_STAFF_TEST_STAFF_GROUPS = ({groups})" in workforce
    mailbox = (REPO / "accounts" / "aa365" / "e2e_mailbox.tf").read_text()
    assert f'e2e_mail_crm_staff_recipient = "{tool.E2E_STAFF_LOCAL}@${{local.e2e_mail_domain}}"' in mailbox


def test_e2e_staff_refuses_other_groups_and_other_environments(capsys):
    idp = FakeWorkforceIdp({"e2e-crm-staff@e2e-mail.lumiguides.it.com": "sub-9"}, groups={"crm-ops", "cis-admin"})
    assert run(["e2e-staff", "--apply"], idp) == 1
    assert "cis-admin" in capsys.readouterr().err and idp.added == []
    assert run(["--env", "stg", "e2e-staff", "--apply"], FakeWorkforceIdp()) == 1
    assert "Dev only" in capsys.readouterr().err
