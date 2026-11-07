# Was my GitHub account hacked?

**A plain, 15-minute check you can do in your browser, and what to do, in order, if you find something.**

Every few months a new wave of attacks takes over GitHub accounts with stolen passwords or tokens, then quietly adds
code that copies the secrets out of their repositories. In October 2026 alone, one wave hit about
[1,900 accounts](https://thehackernews.com/2026/10/ghostaction-compromises-about-1900.html) and another planted
branches in [850+ more](https://www.wiz.io/blog/gheist-attempted-scaled-abuse-of-stolen-github-tokens-stumbles). Many
people only found out when a stranger opened an issue on their repository.

The file names change every wave. **The signs below don't**, because they look at *what changed* in your account,
not at one attack's file names. Attackers make their changes under *your* name, so "did I make this?" is the
question to ask about everything you see.

> **This guide never asks for your password, tokens or logs, and neither should anyone helping you.** Every link
> below goes to github.com or docs.github.com.

**Jump to:** [Someone is in my account right now](#someone-is-in-my-account-right-now) ·
[The 15-minute check](#the-15-minute-check) · [What real attacks looked like](#what-real-attacks-looked-like) ·
[I found something: what to do, in order](#i-found-something-what-to-do-in-order) ·
[Keep it from happening again](#keep-it-from-happening-again)

---

## Someone is in my account right now

Do these in order. It takes about 10 minutes.

1. **Change your GitHub password:** [Password and authentication](https://github.com/settings/security).
   If your email account might be hacked too, secure that first: whoever controls your email can reset your
   GitHub password.
2. **Remove email addresses that aren't yours:** [Emails](https://github.com/settings/emails). An attacker's
   address could let them force a password reset.
3. **End sessions you don't recognise:** [Sessions](https://github.com/settings/sessions). Use **Revoke session**
   on each one. A new password may not sign out other sessions on its own, so don't skip this.
4. **Cancel access you didn't give.** Revoke anything you don't recognise, or anything you no longer use:
   - Tokens (passwords for apps and scripts): [classic tokens](https://github.com/settings/tokens) and
     [fine-grained tokens](https://github.com/settings/personal-access-tokens)
   - [SSH and GPG keys](https://github.com/settings/keys)
   - Apps: [OAuth apps](https://github.com/settings/applications),
     [authorized GitHub Apps](https://github.com/settings/apps/authorizations) and
     [installed GitHub Apps](https://github.com/settings/installations)
5. **Turn on two-factor sign-in**, ideally with a passkey or security key:
   [Password and authentication](https://github.com/settings/security).
6. **Change your secrets before you delete anything the attacker added.** Deleting a bad workflow doesn't undo what
   it already sent out ([why](#3-change-every-secret-the-attacker-could-have-read)).
7. Then follow [what to do, in order](#i-found-something-what-to-do-in-order), and contact
   [GitHub Support](https://support.github.com/). Account and security problems can be reported on free accounts
   too.

**Can't sign in at all?** Secure your email account, then use the **Can't sign in?** option on
[GitHub Support](https://support.github.com/) ([how](https://docs.github.com/en/support/contacting-github-support/creating-a-support-ticket)).

---

## The 15-minute check

About 5 minutes for your account and 10 for your repositories, if you have a handful. For everything you see,
ask: **did I do this?**

### Part A: your account (about 5 minutes)

**1. Your security log.** Open [Security log](https://github.com/settings/security-log). It keeps the last 90
days. Paste each line below into its search box, one at a time:

| Paste this | It shows |
|---|---|
| `action:user.sign_in_from_unrecognized_device_and_location` | sign-ins from a new device *and* a new place |
| `action:user.sign_in_from_unrecognized_device` | sign-ins from a new device |
| `action:personal_access_token.create` | new fine-grained tokens |
| `action:oauth_authorization.create` | apps you (or someone) gave access to your account |
| `action:public_key.create` | new SSH keys or deploy keys |
| `action:user.add_email` | email addresses added to your account |
| `action:two_factor_authentication.disabled` | two-factor sign-in switched off |
| `action:repo.create` | new repositories |
| `action:repo.access` | repositories switched between private and public |
| `action:repo.rename` | renamed repositories |
| `action:hook.create` | new webhooks (they send your repo's events to another server) |
| `action:repo.add_member` | new collaborators |
| `action:repo.create_actions_secret` | new secrets added to a repository's automatic jobs |
| `action:repo.register_self_hosted_runner` | a new computer allowed to run your automatic jobs |
| `action:workflows.delete_workflow_run` | records of automatic job runs that were deleted (some attacks delete them to hide) |

Before you change anything, keep a copy: **Export** (JSON or CSV) at the top of the log. It helps GitHub Support.

**2. [Sessions](https://github.com/settings/sessions):** every device and place should be one you know.

**3. Keys, tokens and apps:** [SSH and GPG keys](https://github.com/settings/keys),
[classic tokens](https://github.com/settings/tokens), [fine-grained tokens](https://github.com/settings/personal-access-tokens),
[OAuth apps](https://github.com/settings/applications), [authorized GitHub Apps](https://github.com/settings/apps/authorizations)
and [installed GitHub Apps](https://github.com/settings/installations). Anything you don't recognise, or don't use
anymore, is worth revoking.

**4. [Emails](https://github.com/settings/emails):** only your own addresses.

**5. [Password and authentication](https://github.com/settings/security):** two-factor sign-in is still on.

### Part B: your repositories (about 10 minutes)

Attacks usually touch many repositories at once. Start with the ones updated most recently, and the ones that hold
secrets (keys or tokens your automatic jobs use).

**6. Your repository list:** `https://github.com/YOUR-USERNAME?tab=repositories` (it's sorted by "last updated").
Look for repositories you didn't create, names or descriptions you didn't write, private repositories that are now
public, and renamed repositories. Also check [Deleted repositories](https://github.com/settings/deleted_repositories)
for anything you didn't delete; in most cases you can restore those yourself for 90 days.

**7. In each repository** (replace `YOU/REPO`):

- **Activity:** `https://github.com/YOU/REPO/activity`. It lists pushes, force pushes and branch changes, and who
  made them. Look for anything you didn't do, especially force pushes (add `?activity_type=force_push`).
- **Branches:** `https://github.com/YOU/REPO/branches/all`. Branches you didn't create, often with machine-made
  names.
- **Automatic jobs (workflows):** the `.github/workflows` folder, on every branch, not just the main one. A new file
  you didn't add is the most common sign of all.
- **Job history:** `https://github.com/YOU/REPO/actions`. Runs you didn't start.
- **Settings** (`https://github.com/YOU/REPO/settings`):
  - **Webhooks**: none you didn't add
  - **Deploy keys**: none you didn't add
  - **Collaborators**: only people you invited
  - **Secrets and variables → Actions**: no secrets you didn't add
  - **Actions → Runners**: no computers you didn't add

**All clear?** Good. Do the same check after any security news about GitHub, and see
[keep it from happening again](#keep-it-from-happening-again).

---

## What real attacks looked like

The names change every time. The pattern doesn't: **new automatic-job files, branches, repositories, keys or
runners that you didn't add.**

| Wave | When | What victims could see | Source |
|---|---|---|---|
| GhostAction | Sep 2025, and again Oct 2026 | A new workflow file, `github_actions_security.yml` in the first wave, added in a commit titled "Add Github Actions Security workflow"; it sent the repository's secrets to the attackers | [GitGuardian](https://blog.gitguardian.com/ghostaction-campaign-3-325-secrets-stolen/), [The Hacker News](https://thehackernews.com/2026/10/ghostaction-compromises-about-1900.html) |
| Shai-Hulud 2.0 | Nov 2025 | New repositories with "Shai-Hulud" in the description, private repositories made public, a self-hosted runner named `SHA1HULUD`, a `discussion.yaml` workflow and `add-linter-workflow-…` branches | [Wiz](https://www.wiz.io/blog/shai-hulud-2-0-ongoing-supply-chain-attack) |
| Gheist | Oct 2026 | `ci-sync-…` branches whose only change was a `sync-check.yml` workflow, commits titled "ci: sync config", workflow runs deleted seconds after they finished, and, on one day, about 1,461 repositories renamed | [Wiz](https://www.wiz.io/blog/gheist-attempted-scaled-abuse-of-stolen-github-tokens-stumbles) |

---

## I found something: what to do, in order

The order matters. Cleaning up first can leave the attacker's stolen keys working.

### 1. Keep a record

Export your [security log](https://github.com/settings/security-log) (JSON or CSV) and take screenshots of what you
found. GitHub Support will ask.

### 2. Lock them out

Do steps 1 to 5 of [someone is in my account right now](#someone-is-in-my-account-right-now): new password, no
strange emails, no strange sessions, no strange tokens, keys or apps, and two-factor sign-in on.

### 3. Change every secret the attacker could have read

Treat every secret in an affected repository as stolen: each repository's **Secrets and variables → Actions**
(and environment secrets), and the real keys behind them, such as cloud keys, package publishing tokens (npm,
PyPI) and API keys. Make new ones at the service that issued them, cancel the old ones there, then save the new
ones in GitHub. GitHub's own advice for a leaked secret is to
[revoke or rotate it first](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/removing-sensitive-data-from-a-repository).
Deleting the bad workflow, its runs or its branch doesn't undo what was already sent.

### 4. Clean up

- Delete the workflow files and branches you didn't add.
- Remove webhooks, deploy keys, collaborators and runners you didn't add.
- Make repositories private again if they were switched to public, and rename them back.
- Restore repositories you didn't delete from [Deleted repositories](https://github.com/settings/deleted_repositories)
  (possible for 90 days).

### 5. Check what you publish

If you publish packages or releases, look for versions you didn't publish. If there are any, remove them and tell
the people who use them.

### 6. Tell GitHub Support

Open a ticket at [GitHub Support](https://support.github.com/) with your exported log and screenshots. They can
help with accounts an attacker changed.

### 7. Find the leak

Your token or password came from somewhere: often malware on a computer, a poisoned package, or a token pasted
into a public place. If a computer might be infected, clean it before you make new tokens on it.

---

## Keep it from happening again

- **Sign in with a [passkey](https://docs.github.com/en/authentication/authenticating-with-a-passkey/about-passkeys)
  or a security key.** GitHub calls passkeys "highly phishing-resistant".
- **Use fine-grained tokens with an expiry date,** limited to the repositories they need
  ([how](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens)).
- **Keep [push protection](https://docs.github.com/en/code-security/secret-scanning/introduction/about-push-protection)
  on.** It stops you pushing secrets to public repositories ([your setting](https://github.com/settings/security_analysis)).
- **In each repository, under Settings → Actions → General,** require approval for workflows from all outside
  contributors, and keep workflow permissions read-only
  ([how](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/enabling-features-for-your-repository/managing-github-actions-settings-for-a-repository)).
- **If you publish releases, turn on
  [release immutability](https://docs.github.com/en/code-security/how-tos/secure-your-supply-chain/establish-provenance-and-integrity/prevent-release-changes),**
  so nobody can quietly swap your files later.

---

## About this guide

- **Checked against GitHub's documentation on 7 November 2026.** Settings pages and security-log names change
  sometimes; if a step no longer matches what you see, please
  [tell us](https://github.com/Echolonius/was-my-github-hacked/issues/new?template=correction.yml).
- **Seen a sign this guide misses?** [Add it](https://github.com/Echolonius/was-my-github-hacked/issues/new?template=new-sign.yml),
  with a public source. Never post your own logs, tokens or keys.
- **Next:** a small read-only checker that runs the repository checks for you. Watch this repository to hear when
  it's ready.
- Not affiliated with GitHub. This is a checklist, not a replacement for [GitHub Support](https://support.github.com/).
- Written with AI help (Claude Code) under the direction of [Echolonius](https://github.com/Echolonius), and
  checked line by line against the sources below.

### Sources

GitHub Docs:
[Reviewing your security log](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/reviewing-your-security-log) ·
[Security log events](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/security-log-events) ·
[Preventing unauthorized access](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/preventing-unauthorized-access) ·
[Viewing and managing your sessions](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/viewing-and-managing-your-sessions) ·
[Reviewing your deploy keys](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/reviewing-your-deploy-keys) ·
[Reviewing your authorized OAuth apps](https://docs.github.com/en/apps/oauth-apps/using-oauth-apps/reviewing-your-authorized-oauth-apps) ·
[Reviewing and revoking GitHub Apps](https://docs.github.com/en/apps/using-github-apps/reviewing-and-revoking-authorization-of-github-apps) ·
[The activity view](https://docs.github.com/en/repositories/viewing-activity-and-data-for-your-repository/using-the-activity-view-to-see-changes-to-a-repository) ·
[Removing sensitive data](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/removing-sensitive-data-from-a-repository) ·
[Restoring a deleted repository](https://docs.github.com/en/repositories/creating-and-managing-repositories/restoring-a-deleted-repository) ·
[Creating a support ticket](https://docs.github.com/en/support/contacting-github-support/creating-a-support-ticket)

Attack write-ups:
[GitGuardian on GhostAction](https://blog.gitguardian.com/ghostaction-campaign-3-325-secrets-stolen/) ·
[The Hacker News on GhostAction, Oct 2026](https://thehackernews.com/2026/10/ghostaction-compromises-about-1900.html) ·
[Wiz on Shai-Hulud 2.0](https://www.wiz.io/blog/shai-hulud-2-0-ongoing-supply-chain-attack) ·
[Wiz on Gheist](https://www.wiz.io/blog/gheist-attempted-scaled-abuse-of-stolen-github-tokens-stumbles)

MIT licensed. Share it with anyone who might need it.
