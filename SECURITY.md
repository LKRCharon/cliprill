# Security policy

Security fixes target the latest published release. Earlier releases may require
an upgrade rather than receiving a backport.

Report vulnerabilities through [GitHub private vulnerability reporting](https://github.com/LKRCharon/cliprill/security/advisories/new).
Include the affected version, reproduction steps and a small synthetic example.
Do not put real clipboard contents, credentials or private documents in a report.
Use ordinary issues for non-security bugs.

Cliprill stores clipboard text locally. Its private Unix socket checks the peer
user ID; it is not an isolation boundary against other software running as that
same macOS user. Configured MCP clients can read history, queue and pinboard text through
the exposed tools. Accessibility access is needed to dispatch paste events.

Preview hiding does not encrypt stored data or restrict explicit MCP reads.

Release binaries use a fixed self-signed certificate and are not Developer ID signed or notarized.
Download from this repository's releases and verify `SHA256SUMS.txt` to check file
integrity. Checksums are not a substitute for an Apple developer signature.
