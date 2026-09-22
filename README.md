# InSpec Profile Workflows

Reusable GitHub Actions workflows for building InSpec/CINC-Auditor profile archives and publishing them on request. These are shared workflows, not Marketplace actions.

## How it works

- **Build Profile Archive** runs on pull requests and pushes to `main`. It checks out the calling profile, installs its Gemfile, archives the profile, validates it, cross-checks the vendored dependencies against the lockfile, verifies the archive resolves with no network access, and uploads the archive plus SHA-256 checksum as `release-profile`. It finishes without requesting release approval.
- **Request Profile Release** runs only when someone clicks **Run workflow**. By default, it selects the latest successful push build of the configured workflow on `main`. An optional build run ID selects an older build instead.
- The publication request validates the source run and artifact, confirms the release tag is still available, displays the selected commit/run/tag, and then waits for approval in the calling repository's `Release` environment.
- After approval, it downloads that exact artifact, verifies its checksum, and creates the release/tag at the **original build commit**. Nothing is rebuilt.

The selected run and immutable artifact ID are fixed before approval. A newer build finishing during review cannot replace the selected archive. “Latest successful” may be older than the newest commit if newer builds failed or are still running; review the selected run shown in the publication summary.

## Add the workflows to a profile

1. Commit and push the shared workflows in this repository.
2. Copy [examples/build.yml](examples/build.yml) to the profile repository's `.github/workflows/build.yml`.
3. Copy [examples/release.yml](examples/release.yml) to `.github/workflows/release.yml`.
4. Replace `WORKFLOW_COMMIT_SHA` in both callers with the same published, full commit SHA from **this repository**.
5. Merge the callers into the profile repository's default branch so GitHub shows the manual **Run workflow** button.

Each profile needs a root-level `Gemfile` installing the selected auditor and an `inspec.yml` with a filename-safe `name` and an `X.Y.Z` version. Configure **Settings → Environments → Release → Required reviewers** in each profile repository. The publishing job fails if reviewers are missing or its token cannot read the protection settings.

The automatic build caller is read-only. The manual publishing caller grants `contents: write` and `actions: read` only to its calling job. The reusable workflow narrows preflight validation to read-only permissions. Cross-run artifact lookup/download now requires `actions: read`; no personal access token or `secrets: inherit` is needed for public dependencies.

The build runs on `pull_request`, including pull requests from forks, and `bundle install` executes install hooks from the Gemfile on the proposed branch. Treat a build runner as untrusted: never pass `secrets: inherit` or an individual secret to the build caller, and do not add steps that need credentials. A regression test asserts that no workflow or example reads a secret or forwards one to a reusable workflow. A profile that genuinely needs credentials to resolve private dependencies should build them in a separate, non-fork-triggered workflow.

Ensure repository/organization settings permit these shared workflows and their pinned actions. Private shared repositories need appropriate Actions access; unrelated public callers need a public shared repository. Required-reviewer availability depends on the repository visibility and GitHub plan.

### Migrating existing callers

The automatic workflow formerly named `release.yml` is now `build.yml`. The manual publishing workflow formerly named `publish.yml` is now `release.yml`. Update the referenced filenames and shared-workflow commit SHA together.

Use `.github/workflows/build.yml` and `.github/workflows/release.yml` for the profile's callers as shown in the examples. Remove the old caller files when renaming them to avoid duplicate workflows. The manual caller's `build-workflow: build.yml` identifies the profile's build workflow, not just the shared workflow.

After renaming the profile's build caller, produce a new successful `main` build before requesting a release. Runs created by the old `release.yml` caller will not match the new expected `build.yml` source workflow.

For migration from the original combined workflow, also remove its `publish: true/false` input and build-job write permission. Existing callers pinned to older SHAs do not change automatically.

Changing workflows does not cancel older runs already waiting for approval. Cancel those separately if they should not publish.

## Request a release

1. Wait for a successful push build on `main`.
2. Open **Actions → Request Profile Release → Run workflow**, with `main` selected.
3. Leave **build-run-id** blank to request the latest successful build, or supply a run ID from a build summary or its URL (`.../actions/runs/<ID>`).
4. Review the selected build link, original commit, and release tag in the publication request's summary.
5. Approve the pending `Release` job.

The request fails before approval if the selected run is from another repository/workflow, is not a successful completed push on the release branch, does not have exactly one unexpired `release-profile` artifact belonging to that commit, or targets a version whose tag already points elsewhere or whose release already exists. It does not silently fall back to an older build if the selected artifact is missing or expired. The publishing job repeats the tag check after approval, because a tag can appear while the request is waiting.

Preflight validation briefly uses a runner. While the subsequent approval is pending, the publishing job has not been sent to a runner, so no runner executes for that waiting job. Unrelated workflows may continue independently. Artifacts are retained for **14 days**, including time spent waiting; an expired artifact requires a new build.

## Workflow inputs

### Build: `.github/workflows/build.yml`

| Input | Default | Purpose |
| --- | --- | --- |
| `auditor` | `cinc-auditor` | Executable installed by the profile's Gemfile: `cinc-auditor` or `inspec`. |
| `ruby-version` | `3.3` | Ruby version used for the build. |

Outputs: `archive` (filename) and `tag` (for example, `v0.1.0`). The archive is named `<name>-<version>.tar.gz` using `inspec.yml`. One profile invocation per build workflow run is supported.

### Publish: `.github/workflows/release.yml`

| Input | Default | Purpose |
| --- | --- | --- |
| `build-run-id` | blank | Select a specific build; blank selects the latest successful push build. |
| `build-workflow` | `build.yml` | Filename of the **calling profile's** automatic build workflow, used to validate the source run. |
| `release-branch` | `main` | Required branch for the source build and the manual request. |

The manual caller intentionally exposes only the optional build ID. Set the expected build workflow and branch in its YAML, not as user-selectable dispatch inputs.

## Versions and offline use

Bump `version` in the profile's `inspec.yml` and build again before publishing a new version. An existing tag must resolve to the original build commit. An existing release is not overwritten; release creation fails if it already exists.

The workflow commit SHA identifies the automation implementation; the build commit SHA identifies the profile source; the archive SHA-256 checksum identifies the asset contents. Publishing an older build never tags the manual request's newer commit.

The archive command vendors profile dependencies at build time; they do not need to be committed. Profiles without dependencies do not need a vendor directory.

Archive validation goes beyond checking that a `vendor/` path exists. The build reads the archived `inspec.lock`, requires the resolved dependency names to match those declared in `inspec.yml`, and requires each resolved dependency to appear as a real vendored profile directory named for its resolved `ref` (or `sha256`) and containing an `inspec.yml`. Dependencies resolved to a local path fetch nothing and are exempt.

The build then re-runs the profile check against the archive with every proxy variable pointed at a blackhole and `--vendor-cache` aimed at an empty directory, so resolution can fall back neither to the network nor to the cache the archive step filled. A profile whose dependencies did not vendor fails this step instead of shipping. This validates dependency resolution, not a live compliance scan: it proves the archive needs no network to load, not that its controls pass on any given target.

The archive includes profile dependencies, **not** the InSpec/CINC runtime or its Ruby gems. Air-gapped runners need those installed separately, including any custom InSpec fork. Private dependencies and licensed runtimes need their own authorized setup; these workflows do not provision credentials or licenses.

## Development

Run local regression tests with:

```sh
ruby test/release_workflow_test.rb
```

Tests exercise metadata, selection/provenance checks, shell steps, checksums, approval protection, and tag/release arguments using fixtures and mocked external commands. They never publish releases. A real GitHub run is still needed to validate cross-repository access and environment approvals.

See GitHub's [reusable workflows](https://docs.github.com/en/actions/how-tos/reuse-automations/reuse-workflows) and [manual workflow runs](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/manually-run-a-workflow) documentation.
