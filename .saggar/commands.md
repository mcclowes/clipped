# Commands

- build: `make build` #writes
- Check signing selection: `node --test scripts/signing-selection.test.mjs` - uses temporary files and stubbed native tools, without real identity lookup or signing #writes #ci
- Check shell syntax: `for script in scripts/*.sh; do bash -n "$script" || exit; done` - parses each helper without executing it #safe #ci
