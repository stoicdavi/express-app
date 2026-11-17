# Troubleshooting AWS OIDC Authentication Failure in GitHub Actions

## 1. Problem Description

While configuring a GitHub Actions workflow to authenticate with AWS, the authentication step failed with the following error:

```text
Could not assume role with OIDC:
Not authorized to perform sts:AssumeRoleWithWebIdentity
```

The failure occurred during the `Configure AWS Credentials` step using:

```yaml
uses: aws-actions/configure-aws-credentials@v6
```

The objective was to authenticate GitHub Actions with AWS using OpenID Connect (OIDC), without storing long-lived AWS access keys in GitHub Secrets.

## 2. Root Cause

The issue was caused by a mismatch between the OIDC subject (`sub`) claim issued by GitHub and the subject condition configured in the AWS IAM role's trust policy.

GitHub introduced immutable OIDC subject claims for repositories created on or after July 15, 2026.

Previously, the subject claim followed this format:

```text
repo:OWNER/REPOSITORY:ref:refs/heads/BRANCH
```

The newer immutable format includes the GitHub owner ID and repository ID:

```text
repo:OWNER@OWNER_ID/REPOSITORY@REPOSITORY_ID:ref:refs/heads/BRANCH
```

My repository, `stoicdavi/express-app`, was created after this change. Consequently, GitHub issued an immutable subject claim, while my initial AWS IAM trust policy expected the older format.

AWS rejected the authentication request because the subject claim did not match the trust policy.

## 3. Retrieving the Actual OIDC Claims

Before updating the trust policy, the exact `sub` claim issued by GitHub must be confirmed. Add a debug job to your workflow to decode the OIDC token and print the relevant claims:

```yaml
jobs:
  debug:
    runs-on: ubuntu-latest
    steps:
      - name: Debug GitHub OIDC claims
        shell: bash
        run: |
          RESPONSE=$(curl -sS \
            -H "Authorization: Bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
            "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=sts.amazonaws.com")

          TOKEN=$(echo "$RESPONSE" | jq -r '.value')

          if [ -z "$TOKEN" ] || [ "$TOKEN" = "null" ]; then
            echo "Could not retrieve OIDC token"
            exit 1
          fi

          export TOKEN

          node -e '
            const token = process.env.TOKEN;
            const claims = JSON.parse(
              Buffer.from(token.split(".")[1], "base64url").toString()
            );

            console.log(JSON.stringify({
              iss: claims.iss,
              aud: claims.aud,
              sub: claims.sub,
              repository: claims.repository,
              repository_id: claims.repository_id,
              repository_owner_id: claims.repository_owner_id,
              ref: claims.ref
            }, null, 2));
          '

          unset TOKEN
```

Push this job to `main` and check the workflow run logs. The output will show the exact `sub` value that GitHub is issuing, for example:

```json
{
  "iss": "https://token.actions.githubusercontent.com",
  "aud": "sts.amazonaws.com",
  "sub": "repo:stoicdavi@12345678/express-app@87654321:ref:refs/heads/main",
  "repository": "stoicdavi/express-app",
  "repository_id": "87654321",
  "repository_owner_id": "12345678",
  "ref": "refs/heads/main"
}
```

Copy the exact `sub` value. You will use it in the IAM trust policy condition.

## 4. Setting Up the IAM OIDC Provider and Role in AWS

Before the trust policy can be updated, the GitHub OIDC provider must be registered in AWS and an IAM role must exist.

### 4.1 Register the GitHub OIDC Provider

Run this once per AWS account:

```bash
aws iam create-open-id-connect-provider \
  --url https://token.actions.githubusercontent.com \
  --client-id-list sts.amazonaws.com \
  --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1
```

Verify it was created:

```bash
aws iam list-open-id-connect-providers
```

### 4.2 Create the IAM Role

Create a file named `trust-policy.json` with the following content, replacing the placeholders with your actual values:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::AWS_ACCOUNT_ID:oidc-provider/token.actions.githubusercontent.com"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com",
          "token.actions.githubusercontent.com:sub": "repo:stoicdavi@OWNER_ID/express-app@REPOSITORY_ID:ref:refs/heads/main"
        }
      }
    }
  ]
}
```

Then create the role:

```bash
aws iam create-role \
  --role-name github-express-deploy \
  --assume-role-policy-document file://trust-policy.json
```

Attach any permissions the workflow needs. For identity verification only:

```bash
aws iam attach-role-policy \
  --role-name github-express-deploy \
  --policy-arn arn:aws:iam::aws:policy/ReadOnlyAccess
```

Retrieve the role ARN to store as a GitHub Actions variable:

```bash
aws iam get-role --role-name github-express-deploy \
  --query 'Role.Arn' --output text
```

In your GitHub repository, open **Settings > Secrets and variables > Actions > Variables** and add:

| Variable | Value |
| --- | --- |
| `AWS_ROLE_ARN` | The role ARN from the command above |

## 5. Solution Implemented

I updated the trust relationship of the AWS IAM role `github-express-deploy` to include the correct GitHub owner ID and repository ID.

The updated trust policy followed this structure:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::AWS_ACCOUNT_ID:oidc-provider/token.actions.githubusercontent.com"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com",
          "token.actions.githubusercontent.com:sub": "repo:stoicdavi@OWNER_ID/express-app@REPOSITORY_ID:ref:refs/heads/main"
        }
      }
    }
  ]
}
```

The actual owner ID and repository ID were used in place of the placeholders.

To update an existing role's trust policy:

```bash
aws iam update-assume-role-policy \
  --role-name github-express-deploy \
  --policy-document file://trust-policy.json
```

The policy restricts authentication to the specified repository and its `main` branch.

## 6. GitHub Actions Configuration

The GitHub Actions workflow required permission to request an OIDC token.

```yaml
name: Test AWS authentication

on:
  push:
    branches:
      - main

permissions:
  id-token: write
  contents: read

jobs:
  authenticate:
    runs-on: ubuntu-latest

    steps:
      - name: Authenticate with AWS
        uses: aws-actions/configure-aws-credentials@v6
        with:
          role-to-assume: ${{ vars.AWS_ROLE_ARN }}
          aws-region: us-east-1

      - name: Verify AWS identity
        run: aws sts get-caller-identity
```

No permanent AWS access keys were required.

## 7. Verification

After updating the IAM trust policy, I reran the GitHub Actions workflow.

The authentication step succeeded, and the following command confirmed that GitHub Actions had successfully assumed the AWS IAM role:

```bash
aws sts get-caller-identity
```

Expected output:

```json
{
  "UserId": "AROAEXAMPLEID:GitHubActions",
  "Account": "123456789012",
  "Arn": "arn:aws:sts::123456789012:assumed-role/github-express-deploy/GitHubActions"
}
```

This verified that AWS had issued temporary credentials to the GitHub Actions workflow.

## 8. Key Lessons Learned

- AWS OIDC authentication depends on matching token claims with the IAM role's trust policy.
- GitHub Actions requires `id-token: write` permission to request an OIDC token.
- The IAM trust policy belongs in AWS, not in the GitHub repository.
- GitHub's immutable subject claims include owner and repository IDs.
- Trust policies should restrict access to specific repositories and branches.
- OIDC provides short-lived credentials and avoids the security risks associated with storing long-lived AWS access keys.
- Always decode the actual OIDC token first to confirm the exact `sub` claim before writing the trust policy.

## 9. Conclusion

The authentication failure was not caused by application code, Docker configuration, or GitHub Actions runner availability. It resulted from an OIDC subject claim mismatch between GitHub and AWS IAM.

Updating the IAM trust policy to recognize GitHub's immutable subject claim resolved the issue and successfully established secure authentication between GitHub Actions and AWS.

**References:**
- [GitHub Actions: OpenID Connect](https://docs.github.com/en/actions/reference/security/oidc)
- [GitHub: Configuring OpenID Connect in AWS](https://docs.github.com/en/actions/how-tos/secure-your-work/security-harden-deployments/oidc-in-aws)
- [AWS IAM: OIDC federation](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_providers_create_oidc.html)
