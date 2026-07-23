/**
 * Tests for shape-remote-readonly hook (Pi twin of shape-remote-readonly.sh).
 * Mirrors cases from shape-remote-readonly_test.sh.
 */

import { describe, it, before, after, beforeEach } from "node:test";
import assert from "node:assert/strict";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";

let tmpDir: string;
let fixtureConfig: string;
let originalPiRole: string | undefined;
let originalClaudeRole: string | undefined;
let originalSshConfigEnv: string | undefined;

before(() => {
  tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "shape-remote-readonly-"));
  fixtureConfig = path.join(tmpDir, "ssh_config");
  fs.writeFileSync(
    fixtureConfig,
    [
      "Host codegen-test-host",
      "    HostName 10.0.0.99",
      "    User testuser",
      "",
      "Host proxied-host",
      "    HostName 10.0.0.100",
      "    User testuser",
      "    ProxyCommand ssh jumpbox -W %h:%p",
      "",
    ].join("\n"),
  );
  originalPiRole = process.env["PI_ROLE"];
  originalClaudeRole = process.env["CLAUDE_ROLE"];
  originalSshConfigEnv = process.env["SHAPE_REMOTE_SSH_CONFIG"];
  process.env["SHAPE_REMOTE_SSH_CONFIG"] = fixtureConfig;
});

after(() => {
  fs.rmSync(tmpDir, { recursive: true, force: true });
  if (originalPiRole === undefined) delete process.env["PI_ROLE"];
  else process.env["PI_ROLE"] = originalPiRole;
  if (originalClaudeRole === undefined) delete process.env["CLAUDE_ROLE"];
  else process.env["CLAUDE_ROLE"] = originalClaudeRole;
  if (originalSshConfigEnv === undefined) delete process.env["SHAPE_REMOTE_SSH_CONFIG"];
  else process.env["SHAPE_REMOTE_SSH_CONFIG"] = originalSshConfigEnv;
});

beforeEach(() => {
  delete process.env["CLAUDE_ROLE"];
  delete process.env["PI_ROLE"];
});

function makeToolCallEvent(toolName: string, command: string) {
  return { toolName, toolCallId: "test-id", input: { command } };
}

const mockPi = {
  on: (_event: string, handler: (event: unknown) => Promise<unknown>) => {
    _capturedHandler = handler;
  },
};
let _capturedHandler: (event: unknown) => Promise<unknown>;

async function runHook(role: string | null, toolName: string, command: string) {
  if (role) {
    process.env["PI_ROLE"] = role;
  }
  const mod = await import("../shape-remote-readonly");
  mod.register(mockPi as unknown as import("@earendil-works/pi-coding-agent").ExtensionAPI);
  return _capturedHandler(makeToolCallEvent(toolName, command));
}

function isDenied(result: unknown): boolean {
  return (result as { block?: boolean } | undefined)?.block === true;
}

const H = "codegen-test-host";

describe("shape-remote-readonly", () => {
  it("local command in shape role — unaffected, allow", async () => {
    const result = await runHook("shape", "bash", "grep -rn foo .");
    assert.equal(isDenied(result), false);
  });

  it("non-shape role — hook inactive even on remote mutation", async () => {
    const result = await runHook("debug", "bash", `ssh ${H} 'apt-get install -y jq'`);
    assert.equal(isDenied(result), false);
  });

  it("non-bash tool — allow", async () => {
    const result = await runHook("shape", "read", `ssh ${H} 'rm -rf /'`);
    assert.equal(isDenied(result), false);
  });

  describe("allowed families", () => {
    it("identity/system: uname", async () => {
      assert.equal(isDenied(await runHook("shape", "bash", `ssh ${H} uname -s`)), false);
    });
    it("files/text: ls", async () => {
      assert.equal(isDenied(await runHook("shape", "bash", `ssh ${H} ls -la /tmp`)), false);
    });
    it("files/text: find without -delete", async () => {
      assert.equal(isDenied(await runHook("shape", "bash", `ssh ${H} find /tmp -name '*.log'`)), false);
    });
    it("processes/network: ps", async () => {
      assert.equal(isDenied(await runHook("shape", "bash", `ssh ${H} ps aux`)), false);
    });
    it("git read-only: status", async () => {
      assert.equal(isDenied(await runHook("shape", "bash", `ssh ${H} git -C /srv/app status`)), false);
    });
    it("packages query: dpkg -l", async () => {
      assert.equal(isDenied(await runHook("shape", "bash", `ssh ${H} dpkg -l jq`)), false);
    });
    it("services status: docker ps", async () => {
      assert.equal(isDenied(await runHook("shape", "bash", `ssh ${H} docker ps`)), false);
    });
    it("HTTP GET/HEAD: curl -sI", async () => {
      assert.equal(isDenied(await runHook("shape", "bash", `ssh ${H} curl -sI https://example.com`)), false);
    });
    it("runtime version: node --version", async () => {
      assert.equal(isDenied(await runHook("shape", "bash", `ssh ${H} node --version`)), false);
    });
    it("runtime version: go version", async () => {
      assert.equal(isDenied(await runHook("shape", "bash", `ssh ${H} go version`)), false);
    });
  });

  describe("wrappers", () => {
    it("sudo -n allowed-command", async () => {
      assert.equal(isDenied(await runHook("shape", "bash", `ssh ${H} sudo -n ls /root`)), false);
    });
    it("command allowed-command", async () => {
      assert.equal(isDenied(await runHook("shape", "bash", `ssh ${H} command ls /tmp`)), false);
    });
    it("sudo WITHOUT -n denies", async () => {
      assert.equal(isDenied(await runHook("shape", "bash", `ssh ${H} sudo ls /root`)), true);
    });
  });

  describe("operators", () => {
    it("pipe, both sides allowed", async () => {
      assert.equal(isDenied(await runHook("shape", "bash", `ssh ${H} 'ps aux | grep nginx'`)), false);
    });
    it("&&, both sides allowed", async () => {
      assert.equal(isDenied(await runHook("shape", "bash", `ssh ${H} 'uname -s && pwd'`)), false);
    });
    it("||, both sides allowed", async () => {
      assert.equal(isDenied(await runHook("shape", "bash", `ssh ${H} 'ls /tmp || pwd'`)), false);
    });
    it("pipe, one side forbidden -> deny", async () => {
      assert.equal(isDenied(await runHook("shape", "bash", `ssh ${H} 'ps aux | rm -rf /tmp'`)), true);
    });
  });

  describe("bounded transport flags", () => {
    it("-n -T allowed", async () => {
      assert.equal(isDenied(await runHook("shape", "bash", `ssh -n -T ${H} uname -s`)), false);
    });
    it("BatchMode=yes allowed", async () => {
      assert.equal(isDenied(await runHook("shape", "bash", `ssh -o BatchMode=yes ${H} uname -s`)), false);
    });
    it("ConnectTimeout out of range denies", async () => {
      assert.equal(isDenied(await runHook("shape", "bash", `ssh -o ConnectTimeout=999 ${H} uname -s`)), true);
    });
    it("unknown flag denies: -A (agent forwarding)", async () => {
      assert.equal(isDenied(await runHook("shape", "bash", `ssh -A ${H} uname -s`)), true);
    });
    it("unknown flag denies: -i identity", async () => {
      assert.equal(isDenied(await runHook("shape", "bash", `ssh -i /tmp/key ${H} uname -s`)), true);
    });
    it("unknown flag denies: -J jump host", async () => {
      assert.equal(isDenied(await runHook("shape", "bash", `ssh -J jumpbox ${H} uname -s`)), true);
    });
    it("unknown ssh -o option denies", async () => {
      assert.equal(isDenied(await runHook("shape", "bash", `ssh -o StrictHostKeyChecking=no ${H} uname -s`)), true);
    });
  });

  describe("host validation", () => {
    it("raw IP host denies (not a config alias)", async () => {
      assert.equal(isDenied(await runHook("shape", "bash", "ssh 10.0.0.55 uname -s")), true);
    });
    it("unconfigured DNS name denies", async () => {
      assert.equal(
        isDenied(await runHook("shape", "bash", "ssh not-a-configured-host.example.com uname -s")),
        true,
      );
    });
    it("wildcard host pattern denies", async () => {
      assert.equal(isDenied(await runHook("shape", "bash", "ssh 'codegen-*' uname -s")), true);
    });
    it("proxied host (ProxyCommand) denies", async () => {
      assert.equal(isDenied(await runHook("shape", "bash", "ssh proxied-host uname -s")), true);
    });
  });

  describe("mutation classes deny", () => {
    it("package install denies", async () => {
      assert.equal(isDenied(await runHook("shape", "bash", `ssh ${H} 'sudo apt-get install -y jq'`)), true);
    });
    it("service restart denies", async () => {
      assert.equal(isDenied(await runHook("shape", "bash", `ssh ${H} systemctl restart nginx`)), true);
    });
    it("container run denies", async () => {
      assert.equal(isDenied(await runHook("shape", "bash", `ssh ${H} docker run -it ubuntu`)), true);
    });
    it("process kill denies", async () => {
      assert.equal(isDenied(await runHook("shape", "bash", `ssh ${H} kill -9 123`)), true);
    });
    it("git write denies (push)", async () => {
      assert.equal(isDenied(await runHook("shape", "bash", `ssh ${H} 'git -C /srv/app push'`)), true);
    });
    it("filesystem write denies (rm)", async () => {
      assert.equal(isDenied(await runHook("shape", "bash", `ssh ${H} rm -rf /tmp/x`)), true);
    });
    it("curl POST denies", async () => {
      assert.equal(isDenied(await runHook("shape", "bash", `ssh ${H} curl -X POST https://example.com`)), true);
    });
    it("sed -i denies", async () => {
      assert.equal(isDenied(await runHook("shape", "bash", `ssh ${H} "sed -i 's/a/b/' /etc/hosts"`)), true);
    });
  });

  describe("interpreter / substitution / redirect / backgrounding", () => {
    it("sh -c wrapper denies", async () => {
      assert.equal(isDenied(await runHook("shape", "bash", `ssh ${H} "sh -c 'rm -rf /tmp'"`)), true);
    });
    it("command substitution denies", async () => {
      assert.equal(isDenied(await runHook("shape", "bash", `ssh ${H} 'echo $(whoami)'`)), true);
    });
    it("redirect denies", async () => {
      assert.equal(isDenied(await runHook("shape", "bash", `ssh ${H} 'ls > /tmp/out.txt'`)), true);
    });
    it("backgrounding denies", async () => {
      assert.equal(isDenied(await runHook("shape", "bash", `ssh ${H} 'sleep 100 &'`)), true);
    });
  });

  describe("unknown verb / malformed payload", () => {
    it("unknown/unclassified verb denies", async () => {
      assert.equal(isDenied(await runHook("shape", "bash", `ssh ${H} some-unknown-binary --flag`)), true);
    });
    it("unbalanced quote in payload denies", async () => {
      assert.equal(isDenied(await runHook("shape", "bash", `ssh ${H} "echo 'unterminated`)), true);
    });
  });
});
