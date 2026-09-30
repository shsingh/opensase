# Contributing

Contributions are welcome. This document defines the working agreement: how
changes are proposed, reviewed, and merged, and what the continuous-integration
gates enforce.

## Ground rules

1. **Never commit to `master`.** All work happens on a branch, one change per
   branch, merged via pull request. Branch names follow
   `<type>/<short-description>` with kebab-case — e.g. `fix/clamd-fail-open`,
   `feat/policy-feed`, `docs/client-setup`.
2. **Conventional Commits.** Every commit message follows
   the [specification](https://www.conventionalcommits.org/en/v1.0.0):
   `type(scope): subject`.
   - Types: `feat`, `fix`, `docs`, `refactor`, `test`, `build`, `ci`, `chore`.
   - `scope` is a component: `nix` (flake/module), `images` (dockerTools),
     `compose`, `vpn`, `policy`, `docs`, `ci`.
   - Subject: imperative, lowercase, no trailing period. Body (optional):
     what changed and why; wrap at 72 columns.
3. **Sign everything.** Commits must be GPG- or SSH-signed
   (`git config --global commit.gpgsign true`); releases are
   [signed tags](docs/ci-release.qmd) — unsigned commits and unsigned tags are
   not merged/published. Verify with `git log --show-signature` / `git tag -v`.
4. **One logical change per PR.** Small, reviewable diffs merge faster.

## Security-sensitive changes

Anything touching the inspection path, the CA material, or the policy engine
warrants extra care (see [SECURITY.md](SECURITY.md) for the full posture):

- **Vulnerabilities are not issues.** Follow [SECURITY.md](SECURITY.md) — never
  open a public issue for an unreported vulnerability.
- **CA and PKI material**: never commit new keys or certificates outside the
  deliberate lab fixtures; `detect-private-key` and the legacy-dir excludes in
  `.pre-commit-config.yaml` draw exactly that line.
- **Policy/default changes** that alter the fail-open/fail-closed posture
  (passlist > bumplist > default-bump) must state the new verdict order and
  include decision-log samples for splice, bump, and INFECTED.
- **Nix-built images:** keep `nix/images.nix` the only image source — no
  Dockerfiles, no `FROM` lines. New runtime dependencies belong in the flake,
  pinned by the lockfile.

## The acceptance suite

```
nix flake check --all-systems --no-build   # everything evaluates, both linux systems
nix develop -c pre-commit run --all-files  # the hook set CI runs
```

`nix flake check` exits 0 only when the appliance module, host layout, QEMU VM
targets and all four container-image derivations evaluate cleanly. For live
behaviour (bump/splice/INFECTED over HTTPS), run the compose stack and probe
with an EICAR file — see [README](README.md#verify-the-pipeline) /
[docs/clients.qmd](docs/clients.qmd).

CI additionally runs on every PR:

| Check       | What it does                                                        |
|---|---|---|
| `flake-check` | `nix flake check --all-systems --no-build` + per-image `--dry-run` builds |
| `pre-commit.ci` | the [.pre-commit-config.yaml](.pre-commit-config.yaml) hook set (no autofix commits to your branch) |

## Commits and PRs

- Push your branch and open a PR against `master`; describe the what and the why.
- Releases are signed tags: `git tag -s vX.Y.Z`; the release workflow refuses
  unsigned tags, builds images, and prepares a draft release with notes and
  SBOMs — see [CI & Release](docs/ci-release.qmd).
- Docs changes (`docs/**`, `index.qmd`, `_quarto.yml`) trigger the
  [pages](https://github.com/shsingh/opensase/actions/workflows/pages.yml)
  workflow on merge.

## Reporting bugs

Open a [GitHub issue](https://github.com/shsingh/opensase/issues/new) with the
flake revision (`nix flake metadata .# --rev` or the release tag), deployment
path (compose / NixOS / QEMU), host OS, and the relevant `decisions.jsonl`
excerpt. Security issues never go here — [SECURITY.md](SECURITY.md) instead.