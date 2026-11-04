# AA-1026 — acc3 invoker role: the availability matrix candidates (S267)

## Decisions

- One new statement `InvokeAvailabilityCandidates` on `AA3-Bedrock-Invoker` (`accounts/acc3-bedrock/main.tf`) for the
  eight acc3 deployments of AA-CIS-App migration 367: Claude Sonnet 4.5, Opus 4.5, Opus 4.6, GPT-6 Sol, GPT-6.1 Sol,
  GPT-6.1 Terra, Kimi K3 (`global.` profiles) and Llama 4 Maverick (`us.` profile; acc3 has no global one).
- ARN shape: the us-west-1 inference-profile ARN, the foundation-model ARN with a region wildcard (a cross-region
  profile is authorized against the model in the member region that serves the call, as `InvokeCohereEmbedV4`), and the
  region-empty foundation-model ARN (the 3-form lesson of AA-397).
- InvokeModel + InvokeModelWithResponseStream only; no Batch permission (the sweep is on-demand).

## Changed

- `accounts/acc3-bedrock/main.tf`: one statement added; the existing statements are untouched (the plan shows an
  in-place update of `aws_iam_role_policy.bedrock_invoker_policy` with one added statement).

## Tradeoffs

- The role may now invoke eight models no stage routes to. Routing stays a data change in CIS (their catalog and
  deployment rows are disabled); the IAM allow only lets the availability sweep get the account's real answer instead
  of an IAM AccessDenied.

## Should know

- Applied by a human with the `nghiep_aa365` profile (not in CI), before the CIS live sweep.
- Not here (followup): us-west-2 on-demand models on acc3 (DeepSeek V3.2, Mistral Large 3, Qwen3 235B, gpt-oss-120b):
  they need a CIS connection `acc3-usw2` and these model ARNs in us-west-2.
- Cost: an IAM policy change, $0.
