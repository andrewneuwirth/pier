# Contributing

Thanks for helping. Read [AGENTS.md](AGENTS.md) first: it explains every source file, where data lives and the rules.

## Build and check

Pier uses MacToolsKit from the [mac-tools-kit](https://github.com/andrewneuwirth/mac-tools-kit) repository. Clone it next to this folder
(`../Kit`) to work on both; otherwise SwiftPM fetches it.

```sh
swift build && .build/debug/Pier --self-check      # must print "self-check ok"
.build/debug/Pier --customize-preview /tmp/shots   # the Customize pages as PNGs, made-up data
./build.sh                                         # build/Pier.app
```

The self-check is the test suite: pure logic only (search ranking, screenshot folder rules, settings migration, Dock
import), never your real Dock or files. New non-trivial logic gets a check next to the existing ones. CI runs the same
build and self-check on every push and pull request.

## Style

- No third-party dependencies beyond MacToolsKit. Apple frameworks only.
- Small, focused code. No speculative abstractions or options nobody asked for.
- A one-line comment for each non-obvious *why*; skip comments that restate the code.
- Colours, radii, spacing and motion come from MacToolsKit (`MT.*`, `Color.mt*`), never literals.
- Swift 5 language mode.
- Never put real names, paths, email addresses or credentials in code, tests or docs; use `/Users/me`, `example.com`.

## Pull requests

Keep them focused on one change, describe what you checked, and include a screenshot for UI changes.
