# Release Process PoC — Setup Instructions

This document captures the **current** and **target** state of the mdoc-builder release process, and
provides step-by-step instructions to stand up a **representative test repository** so the target
release behaviour can be validated in isolation.

- Sections **1 (current state)** and **2 (target state)** are **context** for the implementing agent.
- Section **3 (PoC setup)** is the **actionable work**: what to create in the empty test repo.

The real repo is `github.com/govuk-one-login/mobile-wallet-mdoc-builder`. The test repo is a separate,
initially empty repo where a **GitHub App** has already been installed (used to authenticate the
release job so it can push commits/tags and re-trigger protected checks).

---

## 1. Current state (context)

The release is defined in `.github/workflows/release.yml` and is triggered **only manually** via
`workflow_dispatch`.

### Flow

```
workflow_dispatch (manual)
        │
        ├─ sonarqube.yaml                 (tests + quality gate)              ┐
        ├─ typecheck-lint-format.yaml     (tsc --noEmit, eslint, prettier)   │ gates — all must pass
        ├─ build-and-component-tests.yaml (build + component tests, Node 22/24)│
        ├─ conventional-commits.yaml      (cog check)                        ┘
        │
        └─ create-release   (only if github.ref == refs/heads/main)
              1. checkout (fetch-depth: 0)
              2. cocogitto-action: command=bump, args=--auto  → computes semver, creates git TAG
                 (commits as github-actions[bot])
              3. git push --tags        (if a version was produced)
              4. softprops/action-gh-release → GitHub Release w/ auto-generated notes
```

### Key config (`cog.toml`)

```toml
disable_changelog = true
disable_bump_commit = true      # cog only tags; no bump commit is made
ignore_merge_commits = true
```

`package.json` version is pinned at `0.0.0`.

### What it does

- Validates code quality, types, lint/format, build, component tests, and conventional-commit history.
- Uses cocogitto `bump --auto` to derive the next semver from conventional commits.
- Creates and pushes a **git tag**.
- Creates a **GitHub Release** with auto-generated notes.

### What it does NOT do (current limitations)

1. **Does not update `package.json`** — stays `0.0.0` (because `disable_bump_commit = true`).
2. **Does not publish** to npm or any registry (out of scope).
3. **Not automatic** — manual `workflow_dispatch` only; no trigger on merge to `main`.
4. **No bump commit pushed back** to `main`.

---

## 2. Target ("to-be") state (context)

End goal: **PR merged → release runs → version derived from commits → `package.json` updated →
bump committed → commit + tag pushed.** Publishing stays out of scope.

Two trigger options to demonstrate:

- **Option 1 — automatic:** release triggers on merge/push to `main`.
- **Option 2 — manual:** release still triggerable via `workflow_dispatch`.

Behavioural changes vs. current:

| Aspect                     | Current                          | Target                                             |
| -------------------------- | -------------------------------- | -------------------------------------------------- |
| Trigger                    | manual only                      | on push to `main` (+ keep manual)                  |
| `package.json` version     | untouched (`0.0.0`)              | updated by cog to computed semver                  |
| Bump commit                | none (`disable_bump_commit`)     | cog makes a bump commit                            |
| Push                       | tags only                        | bump commit **and** tag                            |
| Auth for push              | default `GITHUB_TOKEN`           | **GitHub App token** (passes branch protection, re-triggers checks) |
| Publishing                 | out of scope                     | out of scope (unchanged)                           |

Implementation notes for the target (to be proven by the PoC):

- Set `disable_bump_commit = false` in `cog.toml`.
- Add a cog **pre-bump hook** (or `pre_bump_hooks`) to write the version into `package.json`, e.g.
  `npm version {{version}} --no-git-tag-version --allow-same-version` so it is included in the bump commit.
- Authenticate the release job with the **GitHub App** (generate an installation token via
  `actions/create-github-app-token`) and pass that token to checkout + push so the bump commit/tag can be
  pushed to a protected `main` and can re-trigger required checks (a push made with the default
  `GITHUB_TOKEN` does **not** trigger further workflow runs).

---

## 3. PoC setup instructions (the actionable work)

Goal: turn the **empty test repo** into a minimal but representative sandbox that exercises the target
release flow **without** the heavy production tooling (no Sonar, no real library build required). Keep it
small enough to iterate on, but faithful to how cocogitto + conventional commits + the GitHub App token
interact.

### 3.1 Prerequisites (assumed already done / to confirm)

- Test repo created and empty.
- GitHub App installed on the test repo with permissions: **Contents: Read & write**, **Metadata:
  Read-only** (add **Pull requests: Read & write** if PR automation is later tested). Note the App ID and
  generate/download a private key.
- Add repo secrets/vars:
  - `APP_CLIENT_ID` (secret) — the GitHub App client/app ID.
  - `APP_PRIVATE_KEY` (secret) — the App private key (PEM).

### 3.2 Minimal repo scaffold to create

Create these files (a trivial Node package is enough to make `package.json` version bumping meaningful):

```
.
├── package.json
├── .nvmrc
├── cog.toml
├── src/index.js            # trivial, just so the repo has content
└── .github/workflows/release.yml
```

**`package.json`** (minimal — start at `0.0.0`):

```json
{
  "name": "release-poc",
  "version": "0.0.0",
  "private": true,
  "type": "module"
}
```

**`.nvmrc`**:

```
22
```

**`cog.toml`** — enable the bump commit and add a hook that writes the version into `package.json`:

```toml
disable_changelog = true
ignore_merge_commits = true

# Write the computed version into package.json so it is part of the bump commit.
pre_bump_hooks = [
  "npm version {{version}} --no-git-tag-version --allow-same-version",
]
```

> Note: `disable_bump_commit` is intentionally **omitted** (defaults to allowing the bump commit),
> which is the target behaviour. The `pre_bump_hooks` change to `package.json` will be staged into the
> bump commit that cog creates.

**`src/index.js`**:

```js
export const hello = () => "release-poc";
```

### 3.3 Release workflow for the PoC

Create `.github/workflows/release.yml`. This is a trimmed version of the real workflow: it drops the
Sonar/build gates (not needed to prove the release mechanics) and focuses on the **version bump + commit +
tag push using the GitHub App token**. Keep both triggers to demonstrate options 1 and 2.

```yaml
name: Release PoC

on:
  push:
    branches: [main]      # Option 1: automatic on merge to main
  workflow_dispatch: {}   # Option 2: manual

permissions:
  contents: read

concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true

jobs:
  create-release:
    name: Create release
    if: github.ref == 'refs/heads/main'
    runs-on: ubuntu-24.04
    steps:
      # 1. Mint a token from the installed GitHub App so pushes can pass branch
      #    protection and re-trigger workflows (the default GITHUB_TOKEN cannot).
      - name: Generate GitHub App token
        id: app-token
        uses: actions/create-github-app-token@v1
        with:
          app-id: ${{ secrets.APP_CLIENT_ID }}
          private-key: ${{ secrets.APP_PRIVATE_KEY }}

      - name: Check out repository code
        uses: actions/checkout@v4
        with:
          fetch-depth: 0                      # full history for cocogitto
          token: ${{ steps.app-token.outputs.token }}
          persist-credentials: true

      - name: Setup Node.js
        uses: actions/setup-node@v4
        with:
          node-version-file: .nvmrc

      # 2. cocogitto bump: computes semver from conventional commits, runs the
      #    pre_bump_hook (npm version → writes package.json), creates the bump
      #    commit + tag.
      - name: Create semantic release
        id: release
        uses: cocogitto/cocogitto-action@v4
        with:
          command: bump
          args: --auto
          git-user: "release-bot[bot]"
          git-user-email: "release-bot[bot]@users.noreply.github.com"

      # 3. Push the bump commit AND the tag using the App token.
      - name: Push bump commit and tag
        if: steps.release.outputs.version != ''
        run: git push --follow-tags origin HEAD:main
        shell: bash

      # 4. (Optional) GitHub Release — kept to mirror the real workflow.
      - name: Create GitHub release
        if: steps.release.outputs.version != ''
        uses: softprops/action-gh-release@v2
        with:
          token: ${{ steps.app-token.outputs.token }}
          tag_name: ${{ steps.release.outputs.version }}
          generate_release_notes: true
```

> Publishing is intentionally excluded — out of scope for the release process.

### 3.4 Branch protection (to make the test realistic)

To prove the App token is actually required, add branch protection on `main`:

- Require pull request before merging (so history is built from PRs).
- Optionally require status checks.
- **Do not** allow the default `GITHUB_TOKEN`-based actor to bypass — the App must be the one pushing.
  Add the GitHub App to the bypass/allow list for pushing to `main` if push restrictions are enabled.

### 3.5 Test procedure

1. **Seed history:** commit the scaffold with a conventional message (e.g. `feat: initial poc scaffold`)
   on `main`. This establishes a baseline for cog.
2. **Trigger a bump via a real change:**
   - Create a branch, make a change, commit with `feat: add greeting` (minor) or `fix: ...` (patch).
   - Open a PR and merge to `main`.
3. **Option 1 (automatic):** merging to `main` fires the `push` trigger → `create-release` runs.
4. **Verify:**
   - cog computed a new version (job log / `steps.release.outputs.version`).
   - A **bump commit** exists on `main` authored by the App/bot, updating `package.json` `version`.
   - A matching **git tag** was pushed.
   - A **GitHub Release** was created with notes.
   - `package.json` `version` now matches the tag (proves limitation #1 is resolved).
5. **Option 2 (manual):** run the workflow via **Actions → Release PoC → Run workflow** and confirm the
   same behaviour when there are new conventional commits since the last tag (and a no-op / empty version
   when there are none).
6. **Auth check:** confirm the bump commit/tag push succeeded against protected `main` and (if required
   checks are configured) that the push **re-triggered** them — demonstrating the App token behaves
   differently from the default `GITHUB_TOKEN`.

### 3.6 Success criteria

- [ ] Release runs on merge to `main` (Option 1) and via manual dispatch (Option 2).
- [ ] cog derives the correct semver from conventional commits.
- [ ] `package.json` `version` is updated and included in the bump commit.
- [ ] Bump commit **and** tag are pushed to `main` using the GitHub App token.
- [ ] A GitHub Release is created.
- [ ] No publish step runs (out of scope).

### 3.7 Notes / gotchas for the implementing agent

- **`GITHUB_TOKEN` cannot re-trigger workflows** on its pushes and may be blocked by branch protection —
  this is the whole reason the GitHub App token is used. Verify the App token is wired into **both**
  `checkout` (so credentials persist) and the release/GH-release steps.
- Pin third-party actions to commit SHAs for the real repo; version tags (`@v4`) are acceptable in the
  PoC for speed but note the difference.
- cocogitto needs `fetch-depth: 0` — a shallow checkout will break version computation.
- The `pre_bump_hooks` `npm version ... --no-git-tag-version` edit must occur **before** cog creates the
  bump commit so the `package.json` change is captured; confirm the resulting bump commit contains the
  `package.json` diff.
- Keep the first tag/version in mind: with no prior tags, `bump --auto` starts from the appropriate
  initial version based on commit types.

### 3.8 Implementation notes (agreed execution plan)

These notes capture the concrete execution ordering agreed for this test repo. The implementing agent
**must not change any GitHub repo settings** (branch protection, secrets, App install, etc.) — those
steps are performed by the user.

**Execution ordering:**

1. **Create scaffold files EXCEPT the release workflow** — `package.json`, `.nvmrc`, `cog.toml`,
   `src/index.js`.
2. **Seed an inert baseline commit directly to `main`** — commit the scaffold (plus this
   `release-poc.md`) with the conventional message `feat: initial poc scaffold` and push straight to
   `main`. This must **not** trigger a release.
3. **User enables branch protection on `main`** (manual step; agent waits and confirms before
   continuing).
4. **Add the release workflow** (`.github/workflows/release.yml`) only after branch protection is in
   place.
5. **Trigger and validate** the automatic (Option 1) and manual (Option 2) release flows.

**Why the baseline is inert:**

- The seed commit deliberately **omits** `.github/workflows/release.yml`. The release workflow (with its
  `push: branches: [main]` trigger) is added in a later, separate commit — so the baseline push cannot
  fire a release.
- The only workflow present at seed time is the pre-existing `.github/workflows/basic-workflow.yaml`,
  which is `workflow_dispatch`-only and therefore does not run on push.

**Seeding commands (explicit staging — no `git add .`):**

```bash
git add package.json .nvmrc cog.toml src/index.js release-poc.md
git commit -m "feat: initial poc scaffold"
git push origin main
```

**Notes:**

- `release-poc.md` is tracked in the repo (committed as part of the baseline).
- Branch protection is intentionally enabled **after** the baseline is on `main`, so the baseline can be
  pushed directly without requiring a PR.
