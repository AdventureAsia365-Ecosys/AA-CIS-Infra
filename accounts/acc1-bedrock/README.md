# accounts/acc1-bedrock — scheduled for destroy (AA-998)

acc1 (867490540162, a personal account) left the AA ecosystem in S255 (28/10/2026, Linear AA-998). LLM calls
run on acc3 only; all infrastructure is on acc2. Nghiệp accepted losing the cross-account LLM fallback.

Nothing in `accounts/aa365` grants access to this account any more (AssumeRole statements, the Lambda and ECS
`BEDROCK_*_FALLBACK` env and the bronze bucket-policy statements for the acc1 batch role were removed in
`feat/aa-998-remove-acc1-grants`). The app repos (AA-CIS-App, AA-TripPlanner-Web) stopped calling acc1 in
their AA-998 PRs.

Do **not** add resources here. The only remaining step for this root:

1. After the aa365 change above is applied (the bronze bucket policy must no longer name
   `aa-bedrock-batch-inference-role` before that role is deleted), a human runs, with MFA (profile
   `pqnghiep-admin`): `terraform init`, then `terraform plan -destroy -out acc1-destroy.tfplan`, reviews it
   (3 roles: `AA-Bedrock-Invoker`, `AA-CostExplorer-Reader`, `aa-bedrock-batch-inference-role`, and their
   policies), then `terraform apply acc1-destroy.tfplan`.
2. A follow-up PR deletes this directory and the remaining references (`scripts/pre-push.sh` no longer
   depends on it; `docs-gen` stops seeing it once the directory is gone).
3. The state bucket `aa-cis-tfstate-acc1-bedrock-867490540162` is emptied and deleted by hand afterwards
   (DRY RUN list in the AA-998 audit).
