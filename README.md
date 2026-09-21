# InSpec Profile Workflows

Reusable GitHub Actions workflows for building InSpec/CINC-Auditor profile archives and publishing them on request. These are shared workflows, not Marketplace actions.

## How it works

- **Build Profile Archive** runs on pull requests and pushes to `main`. It checks out the calling profile, installs its Gemfile, archives and validates the profile, and uploads the archive plus SHA-256 checksum as `release-profile`. It finishes without requesting release approval.
- **Publish Profile** runs only when someone clicks **Run workflow**. By default, it selects the latest successful push build of the configured workflow on `main`. An optional build run ID selects an older build instead.
- The publication request validates the source run and artifact, displays the selected commit/run/tag, and then waits for approval in the calling repository's `Release` environment.
- After approval, it downloads that exact artifact, verifies its checksum, and creates the release/tag at the **original build commit**. Nothing is rebuilt.

The selected run and immutable artifact ID are fixed before approval. A newer build finishing during review cannot replace the selected archive. “Latest successful” may be older than the newest commit if newer builds failed or are still running; review the selected run shown in the publication summary.

## Add the workflows to a profile

1. Commit and push the shared workflows in this repository.
2. Copy [examples/release.yml](examples/release.yml) to the profile repository's `.github/workflows/release.yml`.
3. Copy [examples/publish.yml](examples/publish.yml) to `.github/workflows/publish.yml`.
4. Replace `WORKFLOW_COMMIT_SHA` in both callers with the same published, full commit SHA from **this repository**.
5. Merge the callers into the profile repository's default branch so GitHub shows the manual **Run workflow** button.

Each profile needs a root-level `Gemfile` installing the selected auditor and an `inspec.yml` with a filename-safe `name` and an `X.Y.Z` version. Configure **Settings → Environments → Release → Required reviewers** in each profile repository. The publishing job fails if reviewers are missing or its token cannot read the protection settings.

The automatic build caller is read-only. The manual publishing caller grants `contents: write` and `actions: read` only to its calling job. The reusable workflow narrows preflight validation to read-only permissions. Cross-run artifact lookup/download now requires `actions: read`; no personal access token or `secrets: inherit` is needed for public dependencies.

Ensure repository/organization settings permit these shared workflows and their pinned actions. Private shared repositories need appropriate Actions access; unrelated public callers need a public shared repository. Required-reviewer availability depends on the repository visibility and GitHub plan.

### Migrating from the combined workflow

The new `release.yml` is **build-only** and no longer accepts `publish` or `release-branch`. When updating a caller's SHA, remove its `publish: true/false` input and job-level write permission, then add the manual publishing caller.

Existing callers pinned to an older SHA do not change automatically. For an interim build-only mode with the old SHA, set `publish: false` and retain the permissions the older workflow declares. After publishing the shared changes, update both callers to the new SHA.

Changing the workflows does not cancel older runs already waiting for approval. Cancel those separately if they should not publish.

## Request a release

1. Wait for a successful push build on `main`.
2. Open **Actions → Publish Profile → Run workflow**, with `main` selected.
3. Leave **build-run-id** blank to request the latest successful build, or supply a run ID from a build summary or its URL (`.../actions/runs/<ID>`).
4. Review the selected build link, original commit, and release tag in the publication request's summary.
5. Approve the pending `Release` job.

The request fails before approval if the selected run is from another repository/workflow, is not a successful completed push on the release branch, or does not have exactly one unexpired `release-profile` artifact belonging to that commit. It does not silently fall back to an older build if the selected artifact is missing or expired.

Preflight validation briefly uses a runner. While the subsequent approval is pending, the publishing job has not been sent to a runner, so no runner executes for that waiting job. Unrelated workflows may continue independently. Artifacts are retained for **14 days**, including time spent waiting; an expired artifact requires a new build.

## Workflow inputs

### Build: `.github/workflows/release.yml`

| Input | Default | Purpose |
| --- | --- | --- |
| `auditor` | `cinc-auditor` | Executable installed by the profile's Gemfile: `cinc-auditor` or `inspec`. |
| `ruby-version` | `3.3` | Ruby version used for the build. |

Outputs: `archive` (filename) and `tag` (for example, `v0.1.0`). The archive is named `<name>-<version>.tar.gz` using `inspec.yml`. One profile invocation per build workflow run is supported.

### Publish: `.github/workflows/publish.yml`

| Input | Default | Purpose |
| --- | --- | --- |
| `build-run-id` | blank | Select a specific build; blank selects the latest successful push build. |
| `build-workflow` | `release.yml` | Filename of the **calling profile's** automatic build workflow, used to validate the source run. |
| `release-branch` | `main` | Required branch for the source build and the manual request. |

The manual caller intentionally exposes only the optional build ID. Set the expected build workflow and branch in its YAML, not as user-selectable dispatch inputs.

## Versions and offline use

Bump `version` in the profile's `inspec.yml` and build again before publishing a new version. An existing tag must resolve to the original build commit. An existing release is not overwritten; release creation fails if it already exists.

The workflow commit SHA identifies the automation implementation; the build commit SHA identifies the profile source; the archive SHA-256 checksum identifies the asset contents. Publishing an older build never tags the manual request's newer commit.

The archive command vendors profile dependencies at build time; they do not need to be committed. Profiles without dependencies do not need a vendor directory. Archive validation is structural, not a live compliance scan or proof of offline execution.

The archive includes profile dependencies, **not** the InSpec/CINC runtime or its Ruby gems. Air-gapped runners need those installed separately, including any custom InSpec fork. Private dependencies and licensed runtimes need their own authorized setup; these workflows do not provision credentials or licenses.

## Development

Run local regression tests with:

```sh
ruby test/release_workflow_test.rb
```

Tests exercise metadata, selection/provenance checks, shell steps, checksums, approval protection, and tag/release arguments using fixtures and mocked external commands. They never publish releases. A real GitHub run is still needed to validate cross-repository access and environment approvals.

See GitHub's [reusable workflows](https://docs.github.com/en/actions/how-tos/reuse-automations/reuse-workflows) and [manual workflow runs](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/manually-run-a-workflow) documentation.
