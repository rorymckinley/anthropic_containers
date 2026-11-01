# Sandbox hardening review -- progress as of 2026-10-11

Pick-up file for the next Claude Code session. Everything below was
produced from *inside* the current (old-config) sandbox container
`claude-code-anthropic-cont`; all output is staged in
`/home/node/outbox-staging/` because the code mount is read-only and the
`/workspace/outbox` volume doesn't exist until the new compose file is
applied. Pull files with `docker cp` (or `scripts/outbox.sh` once pulled).

**Applying the new compose file recreates this container and ends the
running session.** Do it between sessions, and do the SELinux step first
(see "Apply order").

## Where things stand

The original review (start of session) found 7 issues plus small
functional bugs in the staged changes. Status:

| # | Finding | Status |
|---|---------|--------|
| 1 | Egress not enforced: plain bridge network, proxy/DNS advisory only (verified by bypassing both from inside) | **Staged + pulled by Rory.** `internal: true`, `egress` network for dnsmasq/squid only, `gateway_mode_ipv4: isolated` (needs Docker 28+), `enable_ipv6: false` on both networks |
| 2 | Squid hardening untested; config has no writable log/pid paths so it likely won't start as uid 1000 read-only | **Staged.** New `proxy/squid.conf` (paths pinned to stdout/stderr/tmp/none, CONNECT-only on 443, hostname allowlist AND pinned IP), `proxy/Dockerfile` runs `squid -k parse` at build |
| 3 | Persistent home volume = persistent compromise via hooks / MCP servers in `~/.claude/*` | **Staged.** Managed settings tier mounted ro at `/etc/claude-code`: `allowManagedHooksOnly`, `allowManagedPermissionRulesOnly`, `enableArtifact: false` + deny `Artifact`, empty `managed-mcp.json` (exclusive control; also suppresses claude.ai connectors). New env var `CLAUDE_MANAGED_DIR` |
| 4 | Outbox review hazards: sandbox-defining files flow through it; `docker cp -L` follows symlinks; escape-sequence names; files that execute on touch | **Staged + tested.** `scripts/outbox.sh` (list/diff/pull with refusals + warnings), README "Reviewing what comes out" |
| 5 | SELinux rule on parent of all repos drops MCS isolation host-wide; README mechanism explanation was wrong | **Staged.** Pinned level `label=level:s0:c<OCTET>,c1000` on claude service; per-repo `semanage -r` rule; README rewritten with accurate account of what the rule does/doesn't fix |
| 6 | No resource limits: tmpfs without `size=` (each defaults to 50% RAM), no `pids_limit`, no memory limit | **Not started** |
| 7 | Dockerfile supply chain unpinned (`mise.run \| sh`, `get.rvm.io \| bash`, asdf "latest" via GitHub API, `node:22`, claude-code); dead-weight packages (`sudo`, `iptables`, `ipset`, `aggregate`) imply an enforcement layer that doesn't exist | **Not started** |
| -- | Small functional: `/commandhistory` unwritable (confirmed); only uppercase proxy vars; single-file CLAUDE.md bind mount goes stale on rename-save; compose comment references a "Flaw B note" the README doesn't have | **Not started** |

Also surfaced (not in the original 7): the API-as-exfil-channel residual
risk (another account's key) and claude.ai connectors as a network-
invisible egress path -- both now in README "Residual risk".

## Files in `/home/node/outbox-staging/` and whether Rory has pulled them

Pulled (per Rory, "copied across the changes from finding 1"):
- `claude-code/docker-compose.yml.template`, `docker-compose.claude.yml`,
  `README.md` -- **but all three have been changed again since** (findings
  2-5). Re-pull.

Not yet confirmed pulled (produced after that):
- `proxy/squid.conf`, `proxy/Dockerfile`                      (finding 2)
- `claude-code/managed/managed-settings.json`, `managed-mcp.json` (finding 3)
- `claude-code/.env.claude.example`, `.env.claude` (placeholders)  (findings 3, 5)
- `scripts/outbox.sh`  (finding 4; `chmod +x` after pulling)
- `claude-code/docker-compose.yml.template`, `docker-compose.claude.yml`,
  `README.md`  (re-pull: findings 2-5 edits)

Unchanged from the original staged commit (no action): `claude-code/Dockerfile`,
`docker-compose.yaml`, `.gitignore`, `claude-sandbox-planning-notes.md`.

Quick way to see what differs from the repo, from the host:

```bash
C=claude-code-anthropic-cont
for f in README.md docker-compose.claude.yml claude-code/docker-compose.yml.template \
         claude-code/.env.claude.example proxy/squid.conf proxy/Dockerfile; do
  echo "== $f"; docker exec $C cat /home/node/outbox-staging/$f | diff -u $f - | head -5
done
```

## Apply order (when ready to recreate)

1. Pull and review everything above; `git diff`; commit.
2. Host: `docker version` -> Engine 28+? If not, drop the
   `gateway_mode_ipv4: isolated` line and use firewalld instead (README,
   "Host reachability").
3. Host: create `~/.claude-sandbox/managed/`, copy `claude-code/managed/*`
   into it; set `CLAUDE_MANAGED_DIR`, `PERSONAL_CLAUDE_MD_PATH`, Postgres
   creds in the real `.env.claude`.
4. Host: SELinux rule for this repo with `N=0` (README, "SELinux") and
   `restorecon -R`. **Before** recreating -- otherwise the pinned-level
   container can't read the mount.
5. `docker compose -f docker-compose.yaml build` (squid image; the parse
   step validates squid.conf).
6. Smoke-test squid alone:
   `docker run --rm --read-only --user 1000:1000 --cap-drop ALL --security-opt no-new-privileges:true --tmpfs /tmp --tmpfs /run claude-sandbox-squid`
   -- should stay up with no FATAL. If `netdb_filename none` is rejected,
   delete that one line.
7. `docker compose --env-file .env.claude -f docker-compose.claude.yml config` (syntax)
   then `up -d --build`.
8. Run the README "Verification checklist" top to bottom -- it now
   covers findings 1-5 with concrete commands and expected outcomes.

## Next session

- Finding 6: add `pids_limit`, `mem_limit`/`cpus`, and `size=` on every
  tmpfs (`/tmp`, `/run`, Postgres data dir) in the template + instance.
- Finding 7: pin versions in `claude-code/Dockerfile` (node base by
  digest, claude-code, asdf, mise, rvm installer verification), drop
  `sudo`/`iptables`/`ipset`/`aggregate`.
- Small functional items (above).
- Then: the full test pass against the recreated container.

## Context worth remembering

- Claude Code in the image is 2.1.278. Docs were fetched live via the
  proxy from `code.claude.com/docs/en/*.md` (that host resolves to the
  pinned Anthropic IP, so it passes the current ACL -- it will NOT pass
  the new hostname allowlist in finding 2's squid.conf; add
  `code.claude.com` to `anthropic_hosts` if doc lookups from inside the
  sandbox are wanted).
- `/tmp` in the sandbox is `noexec` (Docker tmpfs default) -- scripts
  under it won't run; use `/home/node` for test shims.
- Proxy probe results (current ACL): api/console.anthropic.com,
  platform.claude.com, claude.ai, www.anthropic.com all allowed by the
  pinned IP; statsig.anthropic.com denied.

## Update 2026-10-23 -- toolchain baked into the image

Findings 1-5 confirmed pulled and committed (staging == repo for all of
them). Container still on the old compose; `docker-compose.claude.yml.keep`
in the repo was the new instance file, now superseded by the staged one.

Decisions this session:
- Finding 6 (resource limits): deferred by Rory.
- Finding 7: Rory dropped sudo/iptables/ipset/aggregate on the host. The
  rest (pinning) is folded into the toolchain change below.
- Code mount stays `:ro`. Dependency changes are made on the host
  (lockfile updated there), then the install is repeated in the sandbox.
- Package registries allowed through squid by hostname (index.rubygems.org,
  rubygems.org, repo.hex.pm, registry.npmjs.org). GitHub stays closed.
- Language runtimes are built into the image from .env.claude build args
  (RVM for Ruby; asdf for Erlang/Elixir/Node/k6); mise dropped.

Problems found and fixed in the staged files:
1. Home volume shadowing: anything the image puts under /home/node is
   hidden by the pre-existing claude_node_home volume. Toolchains moved to
   /opt, shell wiring to /etc/bash.bashrc + /etc/profile.d +
   /etc/claude-sandbox/toolchain.sh, bash history to $HOME.
2. /tmp is noexec; ruby-build/rustup execute from TMPDIR. TMPDIR now
   /home/node/tmp (compose env), created by /etc/bash.bashrc.
3. asdf shims weren't on PATH. toolchain.sh prepends /opt/asdf/shims and
   exports ASDF_<TOOL>_VERSION for each baked tool.
Also: lowercase proxy vars + NO_PROXY added; the "Flaw B note" comment
fixed; /commandhistory removed.

Staged (re-pull all): claude-code/Dockerfile, claude-code/docker-compose.yml.template,
claude-code/.env.claude.example, proxy/squid.conf, README.md,
docker-compose.claude.yml (replaces .keep), .env.claude (placeholders),
SESSION-PROGRESS.md.

Not verifiable from inside the sandbox -- check on first build:
- asdf release tag `v0.18.0` exists and ships `asdf-v0.18.0-linux-amd64.tar.gz`
  containing a single `asdf` binary (else adjust ASDF_VERSION).
- `rvm-installer.asc` exists at the 1.29.12 tag path and verifies.
- `rvm-installer --path /opt/rvm --ignore-dotfiles --version 1.29.12` flags
  are accepted; `rvm autolibs disable` then `rvm install` does not try sudo.
- asdf-erlang builds OTP 28.5 with the KERL_CONFIGURE_OPTIONS given
  (drop `--without-megaco` if configure rejects it).
- asdf-elixir accepts `1.18.4-otp-28`; `mix local.hex`/`local.rebar` land
  in /opt/mix and `mix deps.get` at runtime does not try to write /opt/mix.
- `MIX_BUILD_ROOT` is honoured by Elixir 1.18 (else use MIX_BUILD_PATH).
- `rvm alias create default` yields /opt/rvm/wrappers/default on PATH.
- Bundler actually fetches .gem files from rubygems.org (not another
  CDN host) -- watch squid's log on the first `bundle install`.
Then the README verification checklist, which now has toolchain items.

## Update 2026-10-31 -- Claude settings unavailable in the recreated container

Container now runs the new compose file. Inspected from inside it:
- `/etc/claude-code`: `user_home_t:s0`, reads denied. The managed policy is NOT
  in force: the Artifact tool and a claude.ai connector both loaded.
- `~/.claude/CLAUDE.md`: empty root-owned directory created by Docker at 14:43
  because the host file didn't exist, also `user_home_t`. Needs both a real file
  and a label, plus removing the stub directory in the home volume.
- `~/.claude/settings.json` and `~/.claude.json` checked: no planted hooks or
  MCP servers.

Staged (pull these only; the staged `.env.claude` is stale placeholders, do not
pull it over the real one): README.md, docker-compose.claude.yml,
claude-code/docker-compose.yml.template, claude-code/.env.claude.example,
SESSION-PROGRESS.md. Rule is `container_ro_file_t` on both directories; compose
uses long-form binds with `create_host_path: false`.

Not testable from inside the sandbox (no docker, sudo or semanage): the
semanage rule, long-form compose behaviour, the volume stub removal. After the
host steps, re-check with the README verification checklist.

Open, not fixed: `/workspace/outbox` is root:root 755, so uid 1000 can't write
it and the documented outbox workflow doesn't work. The Dockerfile creates
/workspace but not /workspace/outbox, so the volume comes up root-owned. Staging
is still in ~/outbox-staging because of this.

## Update 2026-11-01 -- Ruby sandbox fixes from debugging plentify

Already in the repo's working tree, applied by Rory: RVM wrappers stripped from
PATH in toolchain.sh, `rvm_ignore_gemsets_flag=1` in /etc/rvmrc.

Staged on top of those: BUNDLE_USER_CONFIG baked config (RVM unsets BUNDLE_PATH,
`scripts/functions/selector:187`), /workspace/outbox created in the image (fixes
the open item above), PGDG Postgres client following POSTGRES_VERSION, the
matching compose build arg, and README updates.

Pull: claude-code/Dockerfile, claude-code/docker-compose.yml.template,
docker-compose.claude.yml, claude-code/.env.claude.example, README.md,
SESSION-PROGRESS.md. The staged .env.claude is still stale; do not pull it. The
two compose files and .env.claude.example also carry the 2026-10-31 long-form
bind changes, which the repo doesn't have yet.

Other projects' compose copies, including plentify's, need the
`POSTGRES_VERSION: ${POSTGRES_VERSION}` build arg added by hand.

Not built or run: no docker or real Ruby in this sandbox. The gemset and PATH
behaviour was tested on a stub-ruby copy of RVM. BUNDLE_USER_CONFIG comes from
reading Bundler 2.5.22; plentify runs 4.0.17. First-build checks are in the README
verification checklist.
