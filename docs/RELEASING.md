# Publishing a release

1. Open a PR with the version change, release notes in `docs/releases/<version>.md`,
   and relevant validation results. Keep the bundle version in `scripts/build-app.py`,
   the MCP server version, app status, Settings label and README consistent.
2. Wait for the required `CI` check and squash-merge the PR into `main`.
3. Tag the resulting commit and push the new annotated tag:

   ```sh
   git switch main
   git pull --ff-only
   git tag -a v0.2.0 -m 'Cliprill 0.2.0'
   git push origin v0.2.0
   ```

   Replace `0.2.0` with the new version. Existing release tags cannot be moved or
   deleted; publish a new patch version when a release needs correction.

The Release workflow runs the same CI on the tagged commit. Each native macOS
runner verifies tests, bundles and signs the app, runs the packaged MCP test, and
checks the tag against `CFBundleShortVersionString`. Publishing requires that the
tagged commit belongs to `main` and that matching release notes exist.

The workflow attaches arm64 and x86_64 ZIPs from that run, an archive of the exact
source commit, and SHA-256 checksums. It uploads into a draft before publishing the
complete release. Only the publishing job receives `contents: write`; PR checks
use read permissions and do not receive secrets. Action revisions are pinned and
Dependabot proposes updates weekly. Signing uses an ad-hoc identity; notarization
is not part of this release process.

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
