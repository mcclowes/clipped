import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import {
  copyFileSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

function signingFixture(t, { identities = "", securityExit = 0 } = {}) {
  const root = mkdtempSync(join(tmpdir(), "clipped signing selection-"));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  copyFileSync(new URL("../Makefile", import.meta.url), join(root, "Makefile"));
  const bin = join(root, "bin");
  mkdirSync(bin);
  const probe = join(root, "security.txt");
  const trace = join(root, "xcodebuild.jsonl");
  const recorder = join(root, "record-xcode.mjs");
  writeFileSync(
    join(bin, "security"),
    `#!/bin/sh
printf 'probe\\n' >> "$SIGNING_TEST_PROBE"
printf '%s' "$SIGNING_TEST_IDENTITIES"
exit "$SIGNING_TEST_SECURITY_EXIT"
`,
    { mode: 0o755 },
  );
  writeFileSync(
    join(bin, "xcodebuild"),
    '#!/bin/sh\nexec "$SIGNING_TEST_NODE" "$SIGNING_TEST_RECORDER" "$@"\n',
    { mode: 0o755 },
  );
  writeFileSync(
    recorder,
    `import { appendFileSync } from "node:fs";
const args = process.argv.slice(2);
appendFileSync(process.env.SIGNING_TEST_TRACE, JSON.stringify(args) + "\\n");
if (args.includes("-showBuildSettings")) {
  console.log("    BUILT_PRODUCTS_DIR = /fixture/Build/Products/Release");
}
`,
  );
  const env = { ...process.env };
  for (const key of [
    "MAKEFLAGS",
    "MFLAGS",
    "MAKELEVEL",
    "GNUMAKEFLAGS",
    "DEVELOPER_ID_TEAM",
    "SIGN_ARGS",
  ]) {
    delete env[key];
  }
  Object.assign(env, {
    PATH: `${bin}:${env.PATH}`,
    SIGNING_TEST_NODE: process.execPath,
    SIGNING_TEST_RECORDER: recorder,
    SIGNING_TEST_PROBE: probe,
    SIGNING_TEST_TRACE: trace,
    SIGNING_TEST_IDENTITIES: identities,
    SIGNING_TEST_SECURITY_EXIT: String(securityExit),
  });
  return (args = [], extraEnv = {}, target = "build") => {
    const result = spawnSync(
      "/usr/bin/make",
      ["--no-print-directory", ...args, target],
      {
        cwd: root,
        env: { ...env, ...extraEnv },
        encoding: "utf8",
        timeout: 10000,
      },
    );
    assert.equal(result.status, 0, result.stderr);
    return {
      probes: existsSync(probe)
        ? readFileSync(probe, "utf8").trim().split("\n")
        : [],
      calls: readFileSync(trace, "utf8").trim().split("\n").map(JSON.parse),
    };
  };
}

test("an explicit empty team skips identity discovery", (t) => {
  const run = signingFixture(t);
  const result = run(["DEVELOPER_ID_TEAM="]);
  assert.deepEqual(result.probes, []);
  assert.ok(!result.calls[0].some((arg) => arg.startsWith("CODE_SIGN")));
});

const identities = `  1) AAA "Apple Development: Fixture (OTHER12345)"
  2) BBB "Developer ID Application: Fixture (FIRST12345)"
  3) CCC "Developer ID Application: Fixture (LATER12345)"
`;

function signingArgs(team) {
  return team
    ? [
        "CODE_SIGN_IDENTITY=Developer ID Application",
        "CODE_SIGN_STYLE=Manual",
        `DEVELOPMENT_TEAM=${team}`,
        "PROVISIONING_PROFILE_SPECIFIER=",
        "CODE_SIGNING_ALLOWED=YES",
      ]
    : [];
}

test("an explicit team selects signing without discovery", (t) => {
  const result = signingFixture(t, { identities })([
    "DEVELOPER_ID_TEAM=EXPLICIT12",
  ]);
  assert.deepEqual(result.probes, []);
  assert.deepEqual(result.calls[0].slice(7), signingArgs("EXPLICIT12"));
});

for (const prefix of ["", "-- "]) {
  for (const team of ["", "EXPLICIT12"]) {
    test(`MAKEFLAGS ${JSON.stringify(prefix)} prefix with ${team || "an empty team"} skips discovery`, (t) => {
      const run = signingFixture(t, { identities });
      const result = run([], {
        MAKEFLAGS: `${prefix}DEVELOPER_ID_TEAM=${team}`,
      });
      assert.deepEqual(result.probes, []);
      assert.deepEqual(result.calls[0].slice(7), signingArgs(team));
    });
  }
}

test("explicit signing arguments remain authoritative", (t) => {
  const result = signingFixture(t, { identities })([
    "DEVELOPER_ID_TEAM=EXPLICIT12",
    "SIGN_ARGS=CODE_SIGNING_ALLOWED=NO -jobs 2",
  ]);
  assert.deepEqual(result.probes, []);
  assert.deepEqual(result.calls[0].slice(7), [
    "CODE_SIGNING_ALLOWED=NO",
    "-jobs",
    "2",
  ]);
});

test("MAKEFLAGS transports both empty team and explicit signing arguments", (t) => {
  const result = signingFixture(t, { identities })([], {
    MAKEFLAGS: "DEVELOPER_ID_TEAM= SIGN_ARGS=CODE_SIGNING_ALLOWED=NO",
  });
  assert.deepEqual(result.probes, []);
  assert.deepEqual(result.calls[0].slice(7), ["CODE_SIGNING_ALLOWED=NO"]);
});

for (const target of ["build", "test", "release"]) {
  test(`${target} still discovers the first Developer ID team by default`, (t) => {
    const result = signingFixture(t, { identities })([], {}, target);
    const nativeCall = result.calls.find((args) =>
      args.includes("-configuration"),
    );
    assert.deepEqual(result.probes, ["probe"]);
    assert.deepEqual(nativeCall.slice(0, 7), [
      "-project",
      "Clipped/Clipped.xcodeproj",
      "-scheme",
      "Clipped",
      "-configuration",
      target === "release" ? "Release" : "Debug",
      target === "release" ? "build" : target,
    ]);
    assert.deepEqual(nativeCall.slice(7), signingArgs("FIRST12345"));
  });
}

test("no Developer ID identity preserves the certificate-free fallback", (t) => {
  const result = signingFixture(t, {
    identities: '1) AAA "Apple Development: Fixture (OTHER12345)"',
  })();
  assert.deepEqual(result.probes, ["probe"]);
  assert.deepEqual(result.calls[0].slice(7), []);
});

test("an unavailable discovery command preserves the certificate-free fallback", (t) => {
  const result = signingFixture(t, { securityExit: 1 })();
  assert.deepEqual(result.probes, ["probe"]);
  assert.deepEqual(result.calls[0].slice(7), []);
});

for (const team of ["", "ENVTEAM123"]) {
  test(`ordinary environment ${team || "empty team"} retains automatic discovery`, (t) => {
    const result = signingFixture(t, { identities })([], {
      DEVELOPER_ID_TEAM: team,
    });
    assert.deepEqual(result.probes, ["probe"]);
    assert.deepEqual(result.calls[0].slice(7), signingArgs("FIRST12345"));
  });
}

test("a direct team argument wins over MAKEFLAGS", (t) => {
  const result = signingFixture(t, { identities })(
    ["DEVELOPER_ID_TEAM=DIRECT1234"],
    {
      MAKEFLAGS: "DEVELOPER_ID_TEAM=FLAGTEAM12",
    },
  );
  assert.deepEqual(result.probes, []);
  assert.deepEqual(result.calls[0].slice(7), signingArgs("DIRECT1234"));
});
