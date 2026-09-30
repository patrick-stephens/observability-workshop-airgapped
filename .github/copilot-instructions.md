# Repository Rules

1. Every container image is pinned by tag AND digest. No :latest anywhere, ever. New dependencies must be added to versions.lock with the reason, and versions.lock is never edited without an explicit instruction.
2. Every shell script uses `set -euo pipefail`, is safe to re-run, and logs with a consistent prefix. Never `curl | sh`.
3. Nothing is applied by hand. If a step exists, it exists as a script or a committed manifest. If you do something manually to debug, commit it as a script afterwards.
4. Every `kubectl apply` or `helm install` has a matching, documented teardown in the README.
5. The repo must build and deploy with no outbound network access, other than the initial capture step on the build node. Any network access at runtime is a bug.
6. Prefer explicit over clever. Long, obvious scripts beat short, clever ones. This repo will be read under pressure.
7. Do not add features, dependencies, or abstractions that are not requested. When in doubt, do less and ask.
8. Always run the appropriate linting locally across all files, and resolve any issues found.
