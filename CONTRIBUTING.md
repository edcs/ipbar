# Contributing

```sh
git clone git@github.com:edcs/ipbar.git
cd ipbar
make hooks      # enable the commit-message hook, once per clone
swift test
make run
```

## Commit messages

This repo uses [Conventional Commits](https://www.conventionalcommits.org). Release notes
are generated from the log, so your subject line is what users end up reading.

```
<type>[(scope)][!]: <description>

[optional body]

[optional footers]
```

| Type | For |
| --- | --- |
| `feat` | a new capability |
| `fix` | a bug fix |
| `docs` | documentation only |
| `refactor` | restructuring that doesn't change behaviour |
| `perf` | a performance change |
| `test` | tests only |
| `build` | the Makefile, bundling, or signing |
| `ci` | GitHub Actions |
| `chore` | housekeeping that fits nothing else |
| `style` | formatting with no code change |
| `revert` | reverting an earlier commit |

Add `!` before the colon for a breaking change, like `feat(api)!: rename --diagnose`.

The hook checks four things:

- a known type, an optional `(scope)`, then `: ` and a description
- a subject of 72 characters or fewer. Detail belongs in the body, which has no limit
- no full stop at the end of the subject
- a blank line between the subject and the body

Merge, revert and `fixup!`/`squash!` messages pass through untouched, so interactive
rebases work normally.

```
feat(vpn): detect split tunnels via the default route
fix(prefix): stop /12 blocks overflowing the octet mask
docs: state the minimum macOS version
```

`make hooks` sets `core.hooksPath`. Git stores that per clone rather than in the repo, so
you'll need to run it again on a fresh clone. CI runs the identical script over every
commit in a push or pull request (`Tools/check-commits.sh`), so `--no-verify` only defers
the failure.

## Before you open a pull request

```sh
swift test
make app
./Tools/check-commits.sh origin/main..HEAD
```
