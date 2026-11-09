# Optional phone inbox

The desktop desk is the default. The phone inbox is an opt-in projection of
the same queue to one dedicated **private** GitHub repository, reachable in
[GitHub Mobile](https://docs.github.com/en/get-started/using-github/github-mobile).
The queue is still the source of truth. A sync never scans transcripts and
sends no task context, source repository paths, or session identities.
Decision issues show the question, choices and default; Reviews have a
one-line title. Inline links and mentions are neutralized.

## Activation and use

Apply the queue migration, then configure this on **one** desk machine only.
The owner provisions the dedicated private repository and enables the
integration explicitly. Use the same GitHub account in the desktop CLI and on
the phone. The repository must have Issues enabled and the account must have
administrative access. Pin the repository's numeric ID and the account's numeric
ID rather than trusting a repo or user name alone.

Write a user-owned mode-600 configuration file at
`~/.config/human-queue/mobile.json` (or point `DESK_MOBILE_CONFIG` to that
private file). It holds exactly these keys:

```json
{
  "repo": "owner/private-inbox",
  "repo_id": 123456,
  "operator_id": 234567,
  "signing_key": "<64 lowercase hex characters generated locally>"
}
```

Read the numeric identities with `gh api repos/owner/private-inbox --jq .id`
and `gh api user --jq .id`. Generate the signing key locally, for example with
`openssl rand -hex 32`, and keep it out of Git. If GitHub CLI is installed
outside the standard locations, set `DESK_MOBILE_GH_BIN` to the absolute path
of its trusted executable. The next desk tick verifies the destination is
private and checks the pinned identities before it projects anything.
It does not modify notification preferences. Use GitHub Mobile to open the
inbox; push notification delivery depends on GitHub settings.

- Reply `answer: A` to select an option or `answer: your text` to answer in
  words. A reply must be from the pinned operator and unedited. If the queue
  item changed since projection, use its new issue instead of replying to the
  older one. A valid reply is recorded once and the existing desk wake sends
  only the Decision pointer.
- Reply `reviewed` to mark a Review read. The mirror closes that item's issue
  when the queue accepts the action. Closing the mirror issue by hand does not
  answer a Decision or mark a Review.
- Remove the local config to stop future sync. It does not delete or revoke
  existing GitHub copies; manage those in the dedicated repository.

## Phone acceptance check

After enabling the inbox, raise one synthetic Decision from a live worker and
start an ordinary desk tick. On the phone, verify the Decision is visible,
reply with an option, and verify the worker receives the pointer and reads the
stored answer within the next tick. Also mark a synthetic Review read from its
one-line issue and confirm the queue updates. Inspect both issue bodies to
verify only the projected fields appear. The automated test uses disposable
PostgreSQL and a local GitHub transport stub; it does not claim this phone test.
