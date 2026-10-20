# Docs lint red test (AA-888) — never merge

Throwaway page that proves the Done-when of AA-888: a PR adding an `sg-` ID or a backslash-continued `aws`
command fails CI. Close the PR after the red run.

Open sg-0a1b2c3d4e5f60718 on port 5432.

```bash
aws ec2 describe-security-groups \
  --group-names example --profile aa365-admin --region us-west-1
```
