# Commands

- build: `make build` #writes
- Check signing selection: `node --test scripts/signing-selection.test.mjs` - uses temporary files and stubbed native tools, without real identity lookup or signing #writes #ci
- Check shell syntax: `for script in scripts/*.sh; do bash -n "$script" || exit; done` - parses each helper without executing it #safe #ci
- Check tag release scripts: `node --test scripts/tag-release.test.mjs` - uses temporary branch fixtures and recording Git stubs; never creates real tags or pushes #writes #ci
