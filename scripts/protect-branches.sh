#!/usr/bin/env bash
# Locks down the branches and the TestFlight environment on GitHub.
#
# Run once, after the repository is public (branch rulesets and environment
# reviewers need GitHub Pro/Team on private repos). Needs `gh` logged in as a
# repo admin. Safe to re-run: existing rulesets with the same name are replaced.
#
#   scripts/protect-branches.sh [owner/repo]
set -euo pipefail

REPO="${1:-eveningsco/broadcaster-ios}"
ME_ID=$(gh api user --jq .id)

# Repository admins (role id 5) may bypass the rules, e.g. to delete a merged
# claude/** branch or merge their own PR without a second reviewer.
ADMIN_BYPASS='[{"actor_id": 5, "actor_type": "RepositoryRole", "bypass_mode": "always"}]'

upsert_ruleset() {
  local name="$1" body="$2" id
  id=$(gh api "repos/$REPO/rulesets" --jq ".[] | select(.name == \"$name\") | .id")
  if [ -n "$id" ]; then
    gh api -X PUT "repos/$REPO/rulesets/$id" --input - <<<"$body" >/dev/null
    echo "Updated ruleset: $name"
  else
    gh api -X POST "repos/$REPO/rulesets" --input - <<<"$body" >/dev/null
    echo "Created ruleset: $name"
  fi
}

# main: changes land only through pull requests; no force pushes, no deletion.
upsert_ruleset "Protect main" "$(cat <<JSON
{
  "name": "Protect main",
  "target": "branch",
  "enforcement": "active",
  "bypass_actors": $ADMIN_BYPASS,
  "conditions": {"ref_name": {"include": ["~DEFAULT_BRANCH"], "exclude": []}},
  "rules": [
    {"type": "deletion"},
    {"type": "non_fast_forward"},
    {"type": "pull_request", "parameters": {
      "required_approving_review_count": 0,
      "dismiss_stale_reviews_on_push": true,
      "require_code_owner_review": false,
      "require_last_push_approval": false,
      "required_review_thread_resolution": false
    }}
  ]
}
JSON
)"

# claude/**: agents can keep pushing commits, but history can't be rewritten
# and branches can't be deleted except by an admin.
upsert_ruleset "Protect claude branches" "$(cat <<JSON
{
  "name": "Protect claude branches",
  "target": "branch",
  "enforcement": "active",
  "bypass_actors": $ADMIN_BYPASS,
  "conditions": {"ref_name": {"include": ["refs/heads/claude/**"], "exclude": []}},
  "rules": [
    {"type": "deletion"},
    {"type": "non_fast_forward"}
  ]
}
JSON
)"

# testflight environment: deploys only from main, and each run waits for an
# approval from you before the job (and the App Store Connect key) starts.
gh api -X PUT "repos/$REPO/environments/testflight" --input - >/dev/null <<JSON
{
  "reviewers": [{"type": "User", "id": $ME_ID}],
  "prevent_self_review": false,
  "deployment_branch_policy": {"protected_branches": false, "custom_branch_policies": true}
}
JSON
if ! gh api "repos/$REPO/environments/testflight/deployment-branch-policies" \
     --jq '.branch_policies[].name' | grep -qx main; then
  gh api -X POST "repos/$REPO/environments/testflight/deployment-branch-policies" \
    -f name=main -f type=branch >/dev/null
fi
echo "Configured environment: testflight (main only, approval required)"

cat <<MSG

Last step (needs the key files, so it's manual): move the App Store Connect
secrets into the environment and delete the repo-level copies.

  gh secret set ASC_KEY_ID    --env testflight -R $REPO
  gh secret set ASC_ISSUER_ID --env testflight -R $REPO
  gh secret set ASC_KEY_P8    --env testflight -R $REPO < AuthKey_XXXX.p8
  gh secret delete ASC_KEY_ID    -R $REPO
  gh secret delete ASC_ISSUER_ID -R $REPO
  gh secret delete ASC_KEY_P8    -R $REPO
MSG
