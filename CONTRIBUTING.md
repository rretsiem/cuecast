# Contributing

Thanks for considering a contribution to Cuecast.

## Before You Start

- Keep the core recorder behavior intact: write stream bytes as received and avoid transcoding.
- Keep segment splitting metadata-driven unless a change is explicitly intended.
- Do not commit private station details, personal paths, or real listening data.
- For security problems, use the process in [SECURITY.md](SECURITY.md) instead of opening a public issue.

## Development

Build locally with:

```bash
swift build -c release
./cuecast --help
```

Useful checks before opening a pull request:

```bash
swift build -c release
swift run cuecast --help
```

## Pull Requests

- Keep changes focused and explain the user-visible effect.
- Update documentation when behavior changes.
- Preserve privacy-safe examples in docs and screenshots.
- If a change affects recording semantics, call that out clearly in the PR description.

## Style

- Follow the existing Swift style in the repo.
- Prefer small, reviewable changes over broad refactors.
- Keep terminal output intentional and concise.
