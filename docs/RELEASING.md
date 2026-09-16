# Publishing a release

1. Open a PR with the version change, release notes in `docs/releases/<version>.md`,
   and relevant validation results. Keep the bundle version in `scripts/build-app.py`,
   the MCP server version, app status, Settings label and README consistent.
2. Wait for the required `CI` check and squash-merge the PR into `main`.
3. Tag the resulting commit and push the new annotated tag:

   ```sh
   git switch main
   git pull --ff-only
   git tag -a v0.2.1 -m 'Cliprill 0.2.1'
   git push origin v0.2.1
   ```

   Replace `0.2.1` with the new version. Existing release tags cannot be moved or
   deleted; publish a new patch version when a release needs correction.

The Release workflow runs the same CI on the tagged commit. Each native macOS
runner verifies tests, bundles and signs the app, runs the packaged MCP test, and
checks the tag against `CFBundleShortVersionString`. Publishing requires that the
tagged commit belongs to `main` and that matching release notes exist.

The workflow attaches arm64 and x86_64 ZIPs from that run, an archive of the exact
source commit, the public signing certificate, and SHA-256 checksums. It uploads into a draft before publishing the
complete release. Only the publishing job receives `contents: write`; PR checks
use read permissions and do not receive release secrets. Action revisions are pinned
and Dependabot proposes updates weekly. Official releases use the fixed self-signed
identity in `Signing/Cliprill.pem`; notarization is not part of this release process.
See [signing setup and verification](SIGNING.md). PR/main CI use disposable signing
identities and a separate bundle ID; only tag releases use the release certificate.

If publication fails after creating a draft, inspect the workflow log and draft
assets before retrying. The workflow does not overwrite an existing release.

## Repository administration

The `main` protection configuration is stored in
`.github/branch-protection.json`. After `CI` has run on a new repository, a
repository administrator can apply it with:

```sh
gh api --method PUT repos/LKRCharon/cliprill/branches/main/protection \
  --input .github/branch-protection.json
```

Required status `CI` is restricted to the GitHub Actions app. Administrators must
also use PRs; approval count is zero for solo maintenance. The repository uses
squash merges, deletes merged branches, and protects `v*` tags against update and
deletion. Dependabot alerts, secret scanning, push protection and private security
reporting are enabled in repository settings.

The signing environment and tag-only policy are recorded in
`.github/signing-environment.json` and `.github/signing-tag-policy.json`. Create
the `release-signing` environment with the former and add its deployment-branch
policy from the latter. Upload the two signing credentials as **environment**
secrets, not repository secrets. Do not add those credentials to the `ci`
environment. Apply `.github/release-tag-creation.json` as a tag ruleset to allow
only repository administrators to create `v*` tags. Keep the separate tag
update/deletion protection without bypasses. Release tag creators are trusted
with the workflow definition and signing environment; a workflow-local ancestry
check alone cannot enforce that boundary.

A job without secrets checks protected-main ancestry before any signing job
selects the release environment. Both native signing, package and MCP checks must
pass before publication.
