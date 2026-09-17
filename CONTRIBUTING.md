# Contributing

Bug reports and pull requests are welcome in English or Chinese. For substantial
changes, open an issue describing the workflow first. Use synthetic clipboard text
in tests, screenshots and reports.

See the [developer guide](docs/DEVELOPMENT.md) for the code map, architecture and
additional build options, and the [MCP guide](docs/MCP.md) for the integration API.

## Build and test

Use macOS 14 or later, Xcode 16.4 / Swift 6.1 or later, and Python 3.

```sh
swift package resolve
swift test --disable-automatic-resolution
python3 scripts/build-app.py --output /tmp/Cliprill-QA.app --bundle-id org.cliprill.Cliprill.qa
python3 scripts/smoke-mcp.py /tmp/Cliprill-QA.app
```

The smoke test uses its own short `/tmp` data path, disables clipboard capture and
does not activate sequential paste. It tests the actual packaged app and MCP helper.
To test the UI, start the QA bundle with a separate data directory and `--no-capture`.
See [validation](docs/VALIDATION.md) for physical keyboard testing and its limits.

## Pull requests

- Branch from `main` and keep each PR focused on one problem.
- Run the tests above. Add regression coverage for changes to queue, persistence,
  IPC or MCP behavior. Check visible UI changes in light and dark appearance.
- Keep English and Simplified Chinese strings consistent.
- Preserve dependency licenses. The vendored KeyboardShortcuts package has a
  documented resource-loader patch in `Vendor/KeyboardShortcuts/UPSTREAM.md`.
- Include `Package.resolved` when updating remote dependencies.

GitHub checks both arm64 and x86_64 builds. The required `CI` check succeeds only
when repository checks, Swift tests, signed app packaging and MCP smoke tests all
pass. Changes to `main` go through a PR with an up-to-date branch and resolved
conversations; direct pushes, force pushes and deletion are blocked, including for
administrators. An approving review is optional while this is a solo-maintained
project. Merges use squash commits.

Original contributions are licensed under AGPL-3.0-only, matching the project.
No separate contributor license agreement is required. See [BRAND.md](BRAND.md)
when distributing a modified build.
