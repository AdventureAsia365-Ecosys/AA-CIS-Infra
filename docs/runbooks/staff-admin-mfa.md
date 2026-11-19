# Staff administrators: TOTP enrolment and the MFA switches (AA-1111 S2)

Decision: root ADR 0006c (tech lead S283 "admin MFA = TOTP", S285 "drop the WAF geo rule of the staff hosts once
admin MFA is enforced"). The WORKFORCE pool keeps MFA **optional** with TOTP only, no SMS (`accounts/aa365/identity.tf`,
postcondition). Each staff API refuses an administrator session whose access token's `amr` claim has no `otp` with
**403 `mfa_required`**, but only while its own switch is on:

| App | Who is checked | Switch (default off) | Where it is changed |
|---|---|---|---|
| CIS | `cis-admin`, or the owner flag | `cis.platform.admin_mfa_required` | CIS › Platform › Settings, CIS tab (maker-checker) |
| AA-Partner (CRM) | `crm-platform-admin`, `crm-ops`, `cis-admin` | `crm.platform.admin_mfa_required` | CIS › Platform › Settings, CRM tab (maker-checker) |
| Booking | `booking-admin` | `staff_admin_mfa_required` | Booking › Pricing › Policy, section "Staff sign-in" (two administrators) |

While a switch is off nothing is refused; every administrator session without the code is logged
`staff_admin_mfa_check outcome=would_refuse` (`satisfied` once the code was used), at most once per person every
10 minutes per API task. Desk roles, agency members and the Dev-only E2E identities are never checked.

Order (never change it): **1** merge the code with every switch off → **2** Terraform apply (pool, a no-op today) →
**3** every administrator enrols TOTP (section A) → **4** `staff-totp-check` shows `otp` (section B) → **5** turn the
three switches on (section C) → **6** merge the WAF PR that drops the geo rule for the staff hosts (section D).

## A. Enrol TOTP (each administrator, once; about 3 minutes)

Run it **yourself, in your own terminal**, never through an agent: the setup key is printed once on the screen.
Needs an authenticator app on the phone (Google Authenticator, Microsoft Authenticator, 1Password, ...) and the AWS
admin profile with its MFA (the tool refuses any other account).

1. `aws sts get-caller-identity --profile aa365-admin --region us-west-1` (enter the AWS MFA code if asked).
2. `PY=/home/nghiep/projects/AA-Ecosys/apps/AA-CIS-App/.venv/bin/python`
3. `$PY /home/nghiep/projects/AA-Ecosys/infra/AA-CIS-Infra/tools/identity/workforce_bootstrap.py staff-totp-enroll --email <you>@adventure.asia`
4. Type a new password twice: at least **16** characters with an upper-case letter, a lower-case letter, a digit and a
   symbol. Save it in your password manager: from now on you sign in with **password + 6-digit code**; the e-mail code
   is no longer offered to you.
5. In the authenticator app: **+** → **Enter a setup key** → paste the `Setup key` line (or scan / open the
   `otpauth://` line) → name `AA Staff (dev)` → type **Time based**.
6. Type the 6-digit code the app shows. The tool says `mfa: TOTP enrolled, verified and preferred` and signs you out
   everywhere.

Someone else (the business owner): the tech lead runs step 3 with that person at the keyboard, or the person runs it on
their own machine with their own AWS access. Lost phone: rerun step 3 with `--rotate` (the old app entry stops).

## B. Prove the claim (once, before any switch goes on)

1. `$PY /home/nghiep/projects/AA-Ecosys/infra/AA-CIS-Infra/tools/identity/workforce_bootstrap.py staff-totp-check --email <you>@adventure.asia`
2. Type the password, then the current 6-digit code.
3. Expect the last line `staff-totp-check: OK amr=["pwd", "otp", "mfa"]` (exit 0). `FAIL ... has no "otp"` means
   Amazon Cognito does not write the claim on this pool yet: **stop**, keep every switch off.
4. Sign in on <https://aa-cis.lumiguides.it.com/login> → **Sign in with company email** → choose the password →
   type the code. Then ask the agent to read the CIS log for `staff_admin_mfa_check outcome=satisfied` with your id
   (and Booking / CRM the same after opening <https://booking.lumiguides.it.com> and a CRM operations page).

## C. Turn the switches on (only after A and B for every administrator)

CIS: <https://aa-cis.lumiguides.it.com/admin/platform/settings?app=cis&key=cis.platform.admin_mfa_required>
→ open the setting → New value **On** → Reason `Every administrator has TOTP and staff-totp-check shows otp (AA-1111)`
→ Effective from: leave empty → tick **Approve it now** → **Save and approve** (while two-person approval is on, press
**Propose** and the second administrator presses **Approve**).

CRM: <https://aa-cis.lumiguides.it.com/admin/platform/settings?app=crm&key=crm.platform.admin_mfa_required>
→ the same clicks, New value **On**, the same reason.

Booking: <https://booking.lumiguides.it.com/pricing/policy> → section **Staff sign-in** → **Administrators need an
authenticator code** → **Change** → New value **Yes** → Takes effect on **today** → Reason
`Every administrator has TOTP and staff-totp-check shows otp (AA-1111)` → tick **Submit for approval now** → submit;
the **second Booking administrator** opens the same row and presses **Approve** (the maker never approves their own
version).

Check: sign out and in again with password + code: every page opens. Then the agent checks a session that used only an
e-mail code gets `403 {"detail": "mfa_required"}` (a Dev staff account without TOTP, never a real administrator).

## D. After the switches: the WAF geo rule

Merge the AA-CIS-Infra PR "drop the geo rule for the staff hosts" (it adds the staff hosts to `geo_exempt_hosts`),
then Terraform Apply Dev. Admin pages then open from any country (VPN on or off); MFA and Cognito protect them.

## Roll back

- One administrator locked out (lost phone): the tech lead runs section A step 3 for that address with `--rotate`.
- Everyone locked out: set the switch back to **Off** (CIS and CRM: Platform › Settings; Booking: Pricing › Policy;
  the break-glass account signs in with password + TOTP and holds `cis-admin` + `booking-admin`, root ADR 0006a).
- The pool setting itself never changes: TOTP stays optional for everyone else.
