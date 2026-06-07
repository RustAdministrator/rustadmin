## Disabled GitHub Workflows

These workflows are intentionally stored outside `.github/workflows` so GitHub
does not run them.

They contain full platform build, signing, release, or legacy build-helper jobs.
Before moving any file back into `.github/workflows`, review:

- release/signing jobs must use protected branches or protected tags;
- signing and release secrets should require a GitHub Environment approval;
- downloaded tools and binary payloads need pinned hashes or signature checks;
- pull-request CI must not expose writable cache tokens or release credentials.
