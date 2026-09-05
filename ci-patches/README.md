# CI workflow patch (manual apply required)

The stabilization pass also fixes the GitHub Actions workflows, but those changes
could **not** be pushed from the automation account: GitHub refuses pushes that
create or update files under `.github/workflows/` from a GitHub App that lacks the
`workflows` permission.

```text
! [remote rejected] refusing to allow a GitHub App to create or update workflow
  `.github/workflows/build-mobile.yml` without `workflows` permission
```

So the workflow diff lives here as a patch instead. Apply it locally with a user
account (or re-run the automation after granting the `workflows` scope):

```bash
git apply ci-patches/0001-github-workflow-fixes.patch
git commit -am "ci: repair workflows (see PRODUCTION_READINESS_AUDIT.md)"
git push
```

## What the patch changes

- `.github/workflows/ci.yml` — repairs the **truncated job** (a bare `- name:` step
  with no `run`/`uses`) that made GitHub reject the whole workflow, so CI never ran.
  Also adds the Go backend race/shuffle test step.
- `.github/workflows/build-mobile.yml` — SDK setup alignment, signing secrets guarded
  via job-level `env:` flags (the `secrets` context is not available in `if:`),
  real Gradle errors surfaced through `scripts/flutter_build_apk.sh`.
- `.github/workflows/release.yml` — same signing/SDK alignment, guarded signing steps.
- `.github/workflows/unsigned-release.yml` — SDK setup alignment.
- `.github/workflows/pages.yml` — skips gracefully when the site directory is absent
  instead of failing the run.

Until this patch is applied, the CI workflows on the default branch remain in their
current (broken/unaligned) state — see `docs/history/PRODUCTION_READINESS_AUDIT.md`.
