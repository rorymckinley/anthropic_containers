# Claude Code sandbox template

Shared base for running Claude Code in an isolated container per project:
the project's Ruby/Erlang/Elixir/Node toolchain baked into the image at
build time (RVM for Ruby, asdf for the rest), plus an ephemeral Postgres
sibling, on an `internal` Docker network whose only way out is a squid
proxy with a destination allowlist, non-root, `cap_drop: ALL`, `read_only`
root fs.

## One-time host setup

### SELinux (once per host, then one rule per sandboxed repo)

The code mount is plain `:ro` with no `:Z`. Three reasons not to use `:Z`:

- It relabels the tree only when the container *starts*. A file that
  lands in the repo with the wrong label while the container is running
  stays invisible to it until a restart.
- It assigns the container random MCS categories each start, so there is
  no stable level a persistent host rule could match.
- Any host-wide relabel (`restorecon`, `fixfiles`, some package updates)
  resets the tree to its default type and the running container loses
  access to all of it.

Instead, the claude container's level is **pinned per project** in the
compose file (`label=level:s0:c<PROJECT_NET_OCTET>,c1000`, derived from
the same octet as the subnet), and the repo gets a **persistent
file-context rule carrying that same level**:

```bash
sudo dnf install -y policycoreutils-python-utils     # provides semanage -- once per host

N=<PROJECT_NET_OCTET from this project's .env.claude>
REPO=/absolute/path/to/repo                          # exactly the code-mount source, no trailing slash
sudo semanage fcontext -a -t container_file_t -r "s0:c${N},c1000" "${REPO}(/.*)?"
sudo restorecon -R -v "$REPO"
```

One rule per repo you mount -- **not** the parent directory of all your
repos. A rule on the parent would make every repo under it, sandboxed or
not, container-accessible, and a rule with no level would make them
readable by *any* container on the host at the SELinux layer. With the
level pinned, only the one container carrying `s0:c<N>,c1000` can read
this tree; every other container gets random categories that don't match.
To see or remove rules:

```bash
sudo semanage fcontext -l | grep container_file_t
sudo semanage fcontext -d "${REPO}(/.*)?" && sudo restorecon -R -v "$REPO"
```

Be precise about what this fixes, because it's easy to over-read:

- A file created *in place* in the repo inherits `container_file_t` from
  its directory under either scheme. The rule doesn't change inheritance;
  `:Z` already got this case right.
- A file that *arrives with the wrong type* -- an editor that writes to a
  temp directory and renames into place, a `mv` from elsewhere, a
  `git clone` into the tree from a different context -- is invisible to
  the container under either scheme. Under `:Z` the only fix is a
  container restart. With the rule, it's `sudo restorecon -R "$REPO"` (or
  just the one file), no restart, and the labels survive.
- A file you create on the host gets its *level* from your shell: `s0`,
  no categories, which every container can read. So MCS isolation covers
  the existing tree and anything `restorecon` has touched, not the file
  you made a moment ago. That was equally true under `:Z`.

If a file is missing inside the container: `ls -Z <file>` on the host.
If it isn't `container_file_t`, `restorecon` it.

### SELinux: the Claude settings directories (once per host)

Two more host paths are mounted into every sandbox: `CLAUDE_MANAGED_DIR`
and the directory holding `PERSONAL_CLAUDE_MD_PATH`. Anything under your
home directory is `user_home_t` by default, which a container can't read,
so these need a rule too. The `:ro` on the mount doesn't help, and neither
does the rule on the repo.

```bash
MANAGED_DIR=/absolute/path                # CLAUDE_MANAGED_DIR from .env.claude
PERSONAL_DIR=/absolute/path               # the directory holding PERSONAL_CLAUDE_MD_PATH

mkdir -p "$MANAGED_DIR" "$PERSONAL_DIR"
cp -n claude-code/managed/* "$MANAGED_DIR"/
touch "$PERSONAL_DIR/CLAUDE.md"           # must be a file before the first `up`

for DIR in "$MANAGED_DIR" "$PERSONAL_DIR"; do
  sudo semanage fcontext -a -t container_ro_file_t "${DIR}(/.*)?"
  sudo restorecon -R -F -v "$DIR"
done
```

**Without this rule the sandbox fails open.** Claude Code starts normally
when it can't read `/etc/claude-code`, and none of the managed policy
applies: planted hooks and MCP servers run, claude.ai connectors load, and
the `Artifact` tool is available. Nothing looks broken, so check it with
the verification checklist below.

Why this rule differs from the repo's:

- **No per-project level.** These directories are shared between projects,
  so they can't carry one project's `s0:c<N>,c1000`. At plain `s0`, any
  container that mounts them can read them, so keep credentials out of
  your personal CLAUDE.md. A container can only reach them if they're
  mounted into it.
- **`container_ro_file_t`, not `container_file_t`.** Containers can read
  this type but not write it, so the policy files stay protected at the
  SELinux layer even if a mount ever loses its `:ro`. Host editors are
  unaffected.
- **The rule covers the directory, not just the file.** A rename-saving
  editor creates a new file, which inherits its type from the directory.
  That's why each path must be a directory of its own: never `~`, or
  `~/.claude`, which holds your host credentials.

A file *moved* in from elsewhere keeps its old type, so run
`sudo restorecon -v <file>` on it. Label changes apply at once, with no
container restart. `PERSONAL_CLAUDE_MD_PATH` is a single-file mount, so
after a rename-save the container keeps seeing the old file until it's
recreated.

**If `CLAUDE.md` turned up as a root-owned directory:** Docker creates
missing bind sources as empty directories, and older copies of the compose
file allowed that. The current one refuses to start instead. Cleaning up
takes both of the `rmdir`s below, because the container start also left an
empty directory inside the home volume, and a file can't be mounted over
it. `down` ends any running session. Don't add `-v`: that deletes the home
volume, including your Claude login.

```bash
docker compose --env-file .env.claude -f docker-compose.claude.yml down
sudo rmdir "$PERSONAL_CLAUDE_MD_PATH"
touch "$PERSONAL_CLAUDE_MD_PATH"          # or copy your real CLAUDE.md here
sudo restorecon -F -v "$PERSONAL_CLAUDE_MD_PATH"
docker run --rm -v <compose project>_claude_node_home:/h alpine rmdir /h/.claude/CLAUDE.md
docker compose --env-file .env.claude -f docker-compose.claude.yml up -d
```

## Networking

Each project gets two networks of its own, not shared with any other
project's stack:

- `anthropic_containers` -- the sandbox network. All four containers
  (claude, Postgres, dnsmasq, squid) sit on it. It is `internal: true`,
  so it has no NAT and no route to anything outside its own `/24`.
- `egress` -- an ordinary NATed bridge that **only dnsmasq and squid**
  are attached to. It is their path to the outside world (squid to the
  Anthropic API, dnsmasq to its upstream resolver). The claude and
  Postgres services must never be attached to it; doing so would hand the
  sandbox a direct route out that bypasses squid entirely.

### Why `internal` is the actual control

`HTTP_PROXY`/`HTTPS_PROXY` and the `dns:` setting are configuration that
cooperative programs honour. They don't stop a process that ignores them.
On an ordinary bridge network a container has the host's full network
reach via NAT, and this was confirmed from inside a running sandbox: a
DNS query sent straight to `8.8.8.8` was answered, an HTTPS request to
`1.1.1.1` by IP with the proxy disabled got a response, and a raw TCP
connect to a GitHub address succeeded -- all while the proxied path to
`example.com` was correctly refused with a 403. The proxy and dnsmasq
were advisory, not enforced.

`internal: true` moves enforcement into the host kernel, where a
capability-less container can't touch it. Containers on an internal
network get no default route (off-subnet connections fail immediately
with "network unreachable"), and Docker adds FORWARD-chain drop rules on
the host for any packet leaving or entering that bridge with an
off-subnet address. On-subnet traffic is unaffected, which is why the
claude container can still reach dnsmasq, squid, and Postgres.

squid is what makes the design work across the two networks: it accepts
a `CONNECT` on its sandbox-side interface and opens a *new* TCP connection
from its egress-side interface. It's an application-layer relay, not a
router -- `ip_forward` is off in its namespace and `cap_drop: ALL` means
it can't be turned on -- and Docker's inter-bridge isolation rules would
drop forwarded traffic between the two bridges anyway. With the sandbox
network sealed, squid's ACL *is* the egress policy; dnsmasq's allowlist
becomes defence in depth (it still makes name-resolving tools fail fast
and closes off DNS as an exfiltration side channel).

### Host reachability and the isolated gateway mode

`internal` alone closes the internet and the LAN but not the host
itself. The bridge's gateway address belongs to the host, and traffic to
it goes through the host's INPUT chain, not FORWARD, so Docker's
internal-network drop rules don't apply. Any host service listening on
all interfaces would be reachable from the sandbox, subject only to the
host firewall. The compose files therefore also set

```yaml
driver_opts:
  com.docker.network.bridge.gateway_mode_ipv4: isolated
```

on the sandbox network. In this mode the bridge gets no address at all,
so there is no host endpoint on the subnet to connect to. **This option
needs Docker Engine 28 or later**; on an older engine `compose up`
rejects it. If you can't upgrade, remove that line and instead block
INPUT from the sandbox subnets with firewalld (Docker bridges land in the
`docker` zone by default, whose target is accept).

### IPv6

Both networks set `enable_ipv6: false` explicitly. Docker user-defined
networks are IPv4-only by default anyway, but the whole design is
IPv4-shaped (squid's ACL pins an IPv4 address, dnsmasq's upstream is an
IPv4 resolver, everything is addressed by IPv4), and a second address
family would be a second thing to seal. If your daemon config turns on
IPv6 for new networks, this setting overrides it for these two. Don't
enable IPv6 on the sandbox network without also setting
`gateway_mode_ipv6: isolated`.

### Why dnsmasq and squid are per-project

dnsmasq and squid are duplicated per project rather than run once and
shared: a single shared pair would still be safe (neither does IP
forwarding between networks it's attached to, and squid's ACL is scoped
by destination, not by source network), but it would couple every
project's egress to one shared pair staying up, and require editing that
shared pair's compose file every time a new project is added.
Duplicating them is a few extra lightweight containers per project in
exchange for zero shared state.

### Addressing

The claude container's `dns:` is pointed at its own project's dnsmasq
rather than Docker's embedded resolver, so compose service-name
resolution doesn't work for any of the four containers -- they address
each other by static IP within their own project's `/24`. Only the third
octet (`PROJECT_NET_OCTET`) changes between projects; the last-octet
addresses (`.53` dnsmasq, `.80` squid, `.200` claude, `.201` postgres)
stay the same in every project's copy. The `egress` network's subnet is
Docker-assigned; nothing addresses anything on it by IP.

## Instantiating for a new project

0. Once per machine (not per project): check `docker version` reports
   Engine 28 or later (needed for the isolated gateway mode -- see
   Networking), then build and tag the dnsmasq/squid images from this
   repo -- `docker compose -f docker-compose.yaml build`. Re-run the build
   after editing `dnsmasq/dnsmasq.conf` or `proxy/squid.conf`; every
   project's containers pick up the change on their next recreate.
1. Copy `claude-code/docker-compose.yml.template` into the project repo as
   `docker-compose.claude.yml`, and copy `claude-code/.env.claude.example`
   as `.env.claude` next to it.
2. Find-and-replace `_change_me` / `change-me` throughout: service/container
   names, the image name, and the host repo path in the code mount.
3. Fill in `.env.claude`: `PROJECT_NET_OCTET` (must be unique among
   projects running at the same time -- start at 0 and increment per
   additional project), `SANDBOX_REPO` (host path to this repo -- the
   claude image is built from its `claude-code/` directory), the toolchain
   versions (see "Toolchains"; match the project's `.tool-versions` /
   `.ruby-version` exactly), Postgres credentials/version, the path to
   your personal CLAUDE.md, and `CLAUDE_MANAGED_DIR`. Never commit this
   file.
4. Once per machine: follow "SELinux: the Claude settings directories"
   above. It copies `claude-code/managed/` to the directory named by
   `CLAUDE_MANAGED_DIR` (every project can point at the same one), creates
   your personal CLAUDE.md if needed, and labels both. See "Managed
   settings" below for what's in the policy.
5. Add the SELinux file-context rule for this repo, using this project's
   `PROJECT_NET_OCTET` -- the `semanage`/`restorecon` pair under "SELinux"
   above. Without it the container can't read the code mount at all.
6. `docker compose --env-file .env.claude -f docker-compose.claude.yml up -d --build`.
   The first build compiles Erlang if a version is set; budget 10-20
   minutes for that layer. Later builds reuse it until the version changes.

## Outbox: pull model, not push

**This isn't just for scratch files.** The code mount is `:ro` by design --
Claude cannot write into the project repo directly, from inside the
container, under any circumstances. That means every change Claude
produces, including what would normally be a direct code edit, has to be
staged somewhere else inside the container and pulled out deliberately by
you. That "somewhere else" is the outbox: a named volume mounted at
`/workspace/outbox`.

Workflow: Claude writes to `/workspace/outbox`, you review what's there
from the host with `docker exec <container> ls -la /workspace/outbox` (or
a shell into the container), and when you're happy, pull specific files
out yourself:

```bash
docker cp <container>:/workspace/outbox/<file> <host-dest>/
```

Why not just bind-mount a host directory read-write and let Claude write
straight through? Two reasons:

- It would make the review step optional rather than structural -- files
  would already be "out" the moment they're written.
- It wouldn't even work reliably if that path were `tmpfs` instead of a
  volume: `docker cp` resolves source paths through the container's
  on-disk mount metadata, not by entering its live process namespace.
  tmpfs has no on-disk backing directory at all, so `cp` can't find
  anything there -- confirmed by directly testing it: a file written to
  `/tmp` (tmpfs) while the container was running and verified present via
  `docker exec` still failed `docker cp` with "could not find the file."
  The same file written under a named-volume-backed path (`/home/node`,
  backed by a real directory under `/var/lib/docker/volumes/...`) copied
  out fine. Hence: the outbox must be a named volume, never tmpfs.

No disk quota is enforced on the outbox volume -- treat it as scratch
space and clear it out periodically.

### Reviewing what comes out

Everything in the outbox was written by a process you are deliberately
treating as potentially compromised. The review step is the control, so
it has to be a real read, not a skim. Use `scripts/outbox.sh` from the
host; it wraps `docker cp` with the checks below built in.

```bash
scripts/outbox.sh <container> list                                   # what's there, with types
scripts/outbox.sh <container> diff  claude-code/Dockerfile  claude-code/Dockerfile
scripts/outbox.sh <container> pull  claude-code/Dockerfile  claude-code/Dockerfile
git diff                                                             # then review in the repo
```

What the script enforces, and why, if you ever bypass it:

- **One regular file at a time.** It refuses symlinks and directories.
  A planted symlink `outbox/notes.md -> ~/.claude/.credentials.json`
  copied with `docker cp -L` would pull the credential file out under an
  innocent name; without `-L` a dangling symlink lands in your repo
  instead. Directories hide dotfiles and symlinks you didn't list.
  Never pass `-L` to `docker cp`.
- **Names are shown through `cat -v`.** A file name can carry terminal
  escape sequences that make `ls` output lie about what's there.
- **Exec bit cleared on pull.** `docker cp` preserves mode bits; a
  pulled script shouldn't be runnable before it has been read.
- **Warnings on files that execute when touched.** `.envrc` (direnv runs
  it on `cd`), anything under `.git/hooks/`, editor task files, Makefiles
  and friends, `package.json` scripts, pre-commit config. Read these
  before the tool that runs them gets a chance to.
- **Warnings on files that define the sandbox.** Compose files,
  Dockerfiles, `squid.conf`, `dnsmasq.conf`, the managed settings. When
  the project being worked on is *this repo*, a compromised session's
  most valuable move is a plausible-looking "fix" that adds a `cap_add`,
  a read-write mount of your home, an `egress` attachment on the claude
  service, or a wider proxy ACL -- and it takes effect on the next
  recreate. Diff these line by line, and be suspicious of any change you
  didn't ask for.
- **Overwrite shows the diff and asks.** So a pull onto an existing file
  is never blind.

## Postgres

Ephemeral by design: `/var/lib/postgresql/data` is `tmpfs`, so data resets
every time the Postgres sibling container is recreated. No published
ports -- reachable only from the claude container over the internal
`anthropic_containers` network, by IP (DNS on that network only resolves
`anthropic.com`/`claude.ai`, so service-name resolution doesn't work here
-- address Postgres by its static `ipv4_address`, matched to `PGHOST`).

## Toolchains

Language runtimes are **built into the image**, one set per project, from
the versions in that project's `.env.claude` (`RUBY_VERSIONS`,
`ERLANG_VERSION`, `ELIXIR_VERSION`, `NODEJS_VERSION`, `K6_VERSION`; empty
means not installed). The compose file passes them as build args to this
repo's `claude-code/Dockerfile`. Base layers are shared between projects
through the build cache; only the toolchain layers differ.

Why in the image rather than installed at runtime:

- **Immutable.** The root fs is `read_only`, so a session can't alter a
  ruby, an OTP install or an asdf shim. Before this, those lived in
  writable volumes and were the main "one bad session persists into the
  next" path left after the managed-settings tier closed hooks and MCP.
- **Less egress.** Runtimes come from ruby-lang.org, nodejs.org and
  GitHub, all fetched at *build* time on the host, where the network is
  open. The sandbox itself only needs the package registries (see "The
  proxy"). GitHub in particular stays closed at runtime.
- **Pinned.** Versions are explicit build args, the RVM installer is
  GPG-verified from a tagged release, asdf and git-delta are pinned (with
  optional SHA256 args), and the asdf plugins can be pinned to commits.

Where things are, and what that means at runtime:

| What | Where | Writable at runtime? |
|---|---|---|
| RVM, rubies, default gems | `/opt/rvm` | No -- use Bundler, see below |
| asdf plugins, installs, shims | `/opt/asdf` | No -- shims are generated at build |
| Hex + rebar3 archives | `/opt/mix` (`MIX_HOME`) | No -- `mix local.*` won't work, isn't needed |
| Shell wiring | `/etc/bash.bashrc`, `/etc/profile.d/`, `/etc/claude-sandbox/toolchain.sh` | No |
| Bundler gems (`BUNDLE_PATH`) | `/home/node/.bundle-path` | Yes (home volume) |
| Mix deps and build (`MIX_DEPS_PATH`, `MIX_BUILD_ROOT`) | `/home/node/mix/` | Yes |
| Hex cache, npm cache, bash history, `TMPDIR` | `/home/node/...` | Yes |

Nothing the image needs at runtime is placed under `/home/node`. Docker
seeds a named volume from image content only when the volume is *empty*
on first attach; a home volume that already exists keeps its old
contents and silently hides anything a new image put there. That is why
the toolchains are in `/opt`, the wiring is in `/etc`, and bash history
is in the home volume rather than the image's `/commandhistory`.

Tool versions are selected the asdf way -- `.tool-versions` in the
project, or the `ASDF_<TOOL>_VERSION` exports in `toolchain.sh` as the
default when no file is in scope. Only the baked versions exist, so a
project's `.tool-versions` must name exactly those. The base image's
node 22 stays underneath (it runs `claude` itself); interactive shells
see the asdf node first via the shims.

**Working with the read-only code mount.** Dependency installs write into
the project tree (`Gemfile.lock`, `deps/`, `_build/`, `node_modules/`),
which is `:ro` here. The workflow is: change the dependency on the host,
run the install there so the lockfile is updated and committed, then run
the same install inside the sandbox, where the compose environment
redirects the writable parts onto the home volume:

- Ruby: `bundle install` with `BUNDLE_PATH` on the home volume and
  `BUNDLE_FROZEN=true`, so an out-of-date lockfile is a clear error
  rather than an `EROFS`. Ad hoc `gem install` into the ruby won't work;
  anything wanted globally goes in the Dockerfile. If a project's own
  `.bundle/config` sets a vendored path, set `BUNDLE_APP_CONFIG` to a
  home-volume directory too -- local config outranks environment.
- Elixir: `mix deps.get` and `mix compile` use `MIX_DEPS_PATH` and
  `MIX_BUILD_ROOT` on the home volume. Hex and rebar3 are pre-installed.
- Node: there is no supported way to relocate `node_modules`. Run
  `npm install` on the host and use the resulting tree read-only. Native
  addons compiled on the host may not load in the container (different
  distro); rebuild those into the image if it matters.
- Anything else that writes into the tree at runtime (Rails `tmp/` and
  `log/`, `coverage/`, `dist/`) needs its own redirect or a read-write
  code mount for that project.

`/tmp` is a `noexec` tmpfs (Docker's default, kept). Builds that compile
and execute in their temp dir -- ruby-build, rustup -- fail there, so
`TMPDIR` points at `/home/node/tmp` instead; `/etc/bash.bashrc` creates it.

## Updating Claude Code or a toolchain version

There's no self-update inside the container, deliberately. The image
installs Claude Code at *build* time (`CLAUDE_CODE_VERSION` in
`.env.claude`, `latest` by default) into a directory that is read-only at
runtime. To pick up a newer version, or to change any language version:
edit `.env.claude`, then rebuild and recreate (`docker compose --env-file
.env.claude -f docker-compose.claude.yml up -d --build`). That ends the
running session, so do it between sessions.

`registry.npmjs.org` is now reachable through the proxy for project
dependencies, so the network is no longer what prevents a runtime
self-update; the read-only install directory is. Keep it that way: the
fix path for a stale Claude Code, a missing header, or a new language
version is the same -- edit, rebuild, recreate -- and the image stays the
single description of what's in the sandbox.

## The proxy

`proxy/squid.conf` is the sandbox's entire egress policy, now that the
sandbox network is `internal`. It is CONNECT-only (no plain-HTTP
proxying), port 443 only, and a request must pass two legs: the hostname
in the `CONNECT` must be one of `api.anthropic.com`,
`console.anthropic.com`, or `platform.claude.com` (the API and the two
OAuth token endpoints -- all Claude Code needs), *and* that hostname must
resolve to Anthropic's pinned address. The hostname leg is a string match
with no DNS involved, so an attacker can't satisfy it with a name they
control; the IP leg guards against a listed name being pointed elsewhere.
Both fail closed. The pinned IP alone would be wider than it looks --
Anthropic fronts `claude.ai`, `www.anthropic.com` and others at the same
address -- which is why the hostname leg exists.

A second ACL, `registry_hosts`, allows CONNECT by hostname only to
`index.rubygems.org`, `rubygems.org`, `repo.hex.pm` and
`registry.npmjs.org`, so `bundle install`, `mix deps.get` and `npm
install` work inside the sandbox. These are CDN-fronted, so there is no
IP leg. The runtimes themselves are baked into the image (see
"Toolchains"), so ruby-lang.org, nodejs.org and github.com are *not*
allowed at runtime. Be clear about what this opens: squid can't see the
method or path inside the tunnel, so `rubygems.org` and
`registry.npmjs.org` are reachable for `gem push` and `npm publish` as
well as for downloads, and keeping your own publish tokens out of the
sandbox does not change that -- a prompt-injected session can bring an
attacker's token. It is the same residual-risk class as the Anthropic API
itself (see "Residual risk"). `index.rubygems.org` and `repo.hex.pm` are
download-only hosts. `github.com` is deliberately absent: `git push`
would make it a general-purpose write channel. The first time you install
a project's dependencies, watch `docker logs squid-proxy-<project>` --
every denied CONNECT names the host a tool actually tried, which is how
to extend the list from evidence rather than guesswork.

squid runs as uid 1000 on a read-only root fs with `cap_drop: ALL`, so
the config pins every path squid might write (access log, cache log, pid
file, netdb, coredump dir) to stdout/stderr, `/tmp`, or `none`. Ubuntu's
compiled-in defaults under `/var/log/squid` and `/run` would otherwise
stop it from starting. The squid Dockerfile runs `squid -k parse` at
build time so a config squid rejects fails the image build rather than
the project's `compose up`.

To check the running proxy from the host:

```bash
docker logs squid-proxy-<project>            # access log + cache log, should show no FATAL/WARNING on start
docker exec claude-code-<project> curl -sS -m 10 -o /dev/null -w '%{http_code}\n' https://api.anthropic.com/   # 4xx = tunnel works
docker exec claude-code-<project> curl -sS -m 10 -I https://www.anthropic.com/   # "CONNECT tunnel failed, response 403"
docker exec claude-code-<project> curl -sS -m 10 -I http://api.anthropic.com/    # 403 from squid (plain HTTP refused)
```

## Managed settings: what a session can't change

The `claude_node_home` volume persists across container recreates, and it
holds Claude Code's user-level state: `~/.claude/settings.json` and
`~/.claude.json`. A prompt-injected session can write to both, and two
things it could plant there would run in every later session of the same
project *without a prompt*: hooks (shell commands fired on session start
or around tool calls) and MCP servers (arbitrary processes started at
launch). That turns one bad session into a persistent one.

Rather than making those files read-only (which breaks Claude Code's own
writes to them), the sandbox mounts a host-controlled directory read-only
at `/etc/claude-code`, which is Claude Code's **managed settings** tier --
the one above user, project, and command-line settings, intended for
administrators. Two files live there, both from `claude-code/managed/`:

- `managed-settings.json` sets `allowManagedHooksOnly: true`. Claude Code
  then runs only hooks defined in managed settings; hooks from user,
  project, local, plugin, and agent-frontmatter sources are blocked. A
  session can still *write* a hook into `~/.claude/settings.json` -- it
  just never executes. (Side effects: the `/goal` command, custom status
  lines, and plugins with a `command` source are disabled too.) It also
  turns off the built-in `Artifact` tool, which publishes pages to
  claude.ai -- a write channel out of the sandbox that bypasses the
  outbox and that the network layer can't see. Two keys do this, belt and
  braces: `enableArtifact: false` removes the tool from the session
  entirely (and per the docs no other settings file can turn it back on),
  and a managed permission `deny` on `Artifact` blocks it if it's ever
  present anyway. Managed deny rules can't be overridden by anything a
  session writes.
- `managed-mcp.json` with an empty `mcpServers` object. Deploying this
  file gives it *exclusive* control: Claude Code loads only the servers it
  lists, so a server registered in `~/.claude.json`, in a project
  `.mcp.json`, via a plugin, or with `--mcp-config` is ignored. It also
  suppresses the claude.ai connectors (Gmail, Drive, Calendar, etc.) --
  deliberately, see Residual risk.

What this does and doesn't cover:

- Covered: hook and MCP persistence, the two no-prompt execution paths.
- Not covered: `~/.bashrc` on the home volume is still writable and bash
  reads it after `/etc/bash.bashrc`, so a session can plant a PATH
  override or an alias that runs when *you* next open a shell there. The
  toolchain itself (rubies, shims, Hex) is read-only in the image and no
  longer a persistence target. That's the ordinary "compromised dev
  environment" risk, contained to this project's sandbox; it doesn't
  reach the host.
- Also covered: permission rules. `allowManagedPermissionRulesOnly: true`
  makes the managed file the *only* source of `allow`/`ask`/`deny` rules.
  Without it, a compromised session could write `"allow": ["Bash(*)"]`
  into `~/.claude/settings.json` and every later session would stop
  prompting -- the same persistence shape as hooks. (If you always run the
  sandbox in bypass mode this costs and gains nothing for `allow` rules;
  `deny` rules apply in every mode regardless.) The costs: always-allow
  choices in prompts disappear and aren't saved, `--allowedTools` is
  ignored, and the project's own `.claude/settings.json` rules are ignored
  too -- even though that file is read-only here and so trustworthy. Any
  baseline `allow` rules you want in every sandbox go in the managed
  file's `permissions.allow` list (empty by default).
- Optional extra: `"permissions": {"disableBypassPermissionsMode":
  "disable"}` rejects `--dangerously-skip-permissions`. Not set by
  default, since running the sandbox in bypass mode is a legitimate way
  to use it.

These protections depend on the container being able to read the files,
and Claude Code doesn't fail if it can't -- see "SELinux: the Claude
settings directories".

To change the policy: edit the files in `CLAUDE_MANAGED_DIR` on the host.
It's a directory mount, so the container sees the edit immediately
regardless of how your editor saves, and Claude Code reloads managed
files when they change -- no container restart, and usually no session
restart.

## Residual risk

- The outbox is the deliberate, reviewed exfiltration path -- its value is
  that nothing leaves without your `docker cp`, not that it's leak-proof.
- The home volume persists across recreates of that *project's*
  container only -- no cross-project sharing, but a compromised session
  could still plant something in `.bashrc`, a Bundler-installed gem under
  `BUNDLE_PATH`, or a Mix dep under `MIX_DEPS_PATH` that survives to the
  next session of the same project. The runtimes and shims themselves are
  read-only in the image. Hooks and MCP servers, the two no-prompt
  vectors, are closed by the managed settings tier above.
- The package registries are allowed by hostname and some of them accept
  publishes on the same name (`rubygems.org`, `registry.npmjs.org`).
  Without your credentials in the sandbox those can't touch *your*
  packages, but an attacker's token in a prompt injection makes them an
  exfiltration path, like the API one above. `index.rubygems.org` and
  `repo.hex.pm` are download-only; `github.com` is not allowed.
- claude.ai connectors are an egress path the network layer can't see.
  Gmail drafts, Drive uploads and the like go from Claude Code to
  Anthropic over the sanctioned proxy path and from Anthropic to Google --
  a prompt-injected session could exfiltrate through them without ever
  leaving the allowlist. `managed-mcp.json` suppresses them in the
  sandbox. If you want one back, list it explicitly there rather than
  re-enabling all of them. The built-in `Artifact` tool is the same kind
  of channel (pages published to claude.ai, private by default but
  shareable) and isn't an MCP server, so it's denied separately via a
  managed permission rule.
- The one allowed egress destination is a multi-tenant service. A
  compromised session that has obtained *someone else's* Anthropic API
  key can send data to `api.anthropic.com` under that key, and the
  network layer can't tell it apart from legitimate traffic (it's all
  inside TLS). The proxy stops exfiltration to anywhere else; it can't
  stop exfiltration *through* Anthropic to another Anthropic account.
- None of this stops a compromised session from trying -- it stops it
  from reaching the host, other projects, or anything beyond the one
  proxy-allowlisted egress path and the one reviewed outbox.

## Verification checklist

- [ ] No write access to the code mount from inside the container.
- [ ] The container runs at the pinned level:
      `docker inspect <claude container> --format '{{.ProcessLabel}}'`
      ends in `s0:c<N>,c1000`, and on the host `ls -Z <repo>/README.md`
      shows `container_file_t:s0:c<N>,c1000`.
- [ ] A file created in place on the host after container start is
      visible inside the container immediately: `touch <repo>/new.txt` on
      the host, `cat /workspace/code/new.txt` in the container.
- [ ] A file moved in from elsewhere is *not* visible until relabelled,
      and relabelling works without a restart: on the host
      `touch /tmp/moved.txt && mv /tmp/moved.txt <repo>/`; in the
      container `cat /workspace/code/moved.txt` fails with permission
      denied; on the host `sudo restorecon -v <repo>/moved.txt`; the
      `cat` now succeeds. (Then check which pattern your editor uses by
      saving a new file from it and repeating the `cat`.)
- [ ] Another container cannot read the tree:
      `docker run --rm -v <repo>:/x:ro alpine cat /x/README.md` fails with
      permission denied. Then prove the test is live:
      `docker run --rm --security-opt label=level:s0:c<N>,c1000 -v <repo>:/x:ro alpine cat /x/README.md`
      succeeds.
- [ ] A file written to the outbox volume comes out cleanly via
      `scripts/outbox.sh <container> pull <file> <dest>`.
- [ ] The helper refuses a symlink. Inside the container:
      `ln -s /home/node/.claude/.credentials.json /workspace/outbox/notes.md`;
      on the host, `scripts/outbox.sh <container> list` shows it as type
      `l`, and `pull notes.md /tmp/notes.md` exits with "refusing".
      Remove the symlink afterwards.
- [ ] The helper warns on a sandbox-defining path: pull any outbox file to
      `/tmp/docker-compose.claude.yml` and confirm the DEFINES THE SANDBOX
      warning appears.
- [ ] Network egress is proxy-only. From a shell inside the claude
      container, all of these must *fail* with "network unreachable" or a
      timeout:

      ```bash
      dig +time=2 +tries=1 @8.8.8.8 example.com        # DNS bypassing dnsmasq
      curl --noproxy '*' -m 5 https://1.1.1.1/          # HTTPS by IP, proxy bypassed
      bash -c 'exec 3<>/dev/tcp/140.82.112.3/443'        # raw TCP to a GitHub IP
      bash -c "exec 3<>/dev/tcp/172.100.${PROJECT_NET_OCTET}.1/22"   # the host's gateway address
      ```

      and these must *succeed*:

      ```bash
      curl -m 10 -o /dev/null -w '%{http_code}\n' https://api.anthropic.com/   # any 4xx = proxied path works
      curl -m 10 -o /dev/null -w '%{http_code}\n' https://index.rubygems.org/   # registry allowed by hostname
      curl -m 10 -o /dev/null -w '%{http_code}\n' https://repo.hex.pm/           # same
      psql -c 'select 1'                                                        # Postgres on-subnet
      ```

      while these must get a 403 from squid (CONNECT refused):

      ```bash
      curl -m 10 -I https://github.com/            # no GitHub at runtime
      curl -m 10 -I https://cache.ruby-lang.org/   # runtimes come from the image, not the network
      ```

      `ip route` should show only the `172.100.X.0/24` line and no
      default route; `ip -6 addr` and `ip -6 route` should print nothing.
- [ ] squid stays up under the hardened settings (read-only, uid 1000,
      `cap_drop: ALL`): `docker ps` shows it running a minute after
      `up`, and `docker logs squid-proxy-<project>` has no `FATAL` and
      no "Cannot open" / "Permission denied" lines.
- [ ] The proxy refuses what it should: `CONNECT` to `www.anthropic.com`
      and plain `http://` to `api.anthropic.com` both get a 403 from squid
      (commands in "The proxy" above).
- [ ] The claude service is attached to `anthropic_containers` only
      (`docker inspect <claude container> --format '{{json .NetworkSettings.Networks}}'`
      lists exactly one network).
- [ ] Managed settings are mounted and read-only: inside the container,
      `cat /etc/claude-code/managed-settings.json` shows the policy and
      `touch /etc/claude-code/x` fails with "Read-only file system". On the
      host, `ls -Z "$CLAUDE_MANAGED_DIR"` shows `container_ro_file_t:s0`.
- [ ] The policy is in force, not just readable. In a session started after
      the label was fixed, `/mcp` lists no claude.ai connectors and the
      `Artifact` tool isn't available.
- [ ] Personal CLAUDE.md is a readable file: inside the container,
      `test -f ~/.claude/CLAUDE.md && cat ~/.claude/CLAUDE.md` shows its
      contents. "Is a directory" or "Permission denied" means the host path
      or label is wrong.
- [ ] A missing settings path stops the stack instead of being created:
      with `PERSONAL_CLAUDE_MD_PATH` pointed at a path that doesn't exist,
      `up` fails with a "bind source path does not exist" error and nothing
      appears at that path.
- [ ] A hook planted in user settings does not run. Inside the container,
      with `~/.claude/settings.json` backed up first:

      ```bash
      cp ~/.claude/settings.json /tmp/settings.bak 2>/dev/null
      cat > ~/.claude/settings.json <<'EOF'
      {"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"touch /tmp/HOOK-RAN"}]}]}}
      EOF
      rm -f /tmp/HOOK-RAN; claude -p 'say ok'; ls /tmp/HOOK-RAN   # expect: No such file
      ```

      Then prove the test is live: on the host, temporarily set
      `allowManagedHooksOnly` to `false`, rerun the last line, and expect
      the file to appear. Set it back to `true`, rerun, expect absent
      again -- that also proves the managed file reloads without a
      restart. Finally restore the backup.
- [ ] An MCP server planted in user config does not start. Inside the
      container:

      ```bash
      rm -f /tmp/MCP-RAN
      claude mcp add --scope user planted -- /bin/sh -c 'touch /tmp/MCP-RAN; sleep 600'
      claude -p 'say ok'; ls /tmp/MCP-RAN   # expect: No such file
      claude mcp list                        # expect: no "planted" entry, or an error that MCP is managed
      claude mcp remove --scope user planted 2>/dev/null
      ```

      Either `mcp add` is refused outright or the server is registered
      but never started; both pass.
- [ ] No claude.ai connectors in the sandbox: `/mcp` inside a session
      lists none (Gmail, Drive, Calendar, Claude Docs should all be
      absent).
- [ ] A permission rule planted in user settings is ignored. Run this one
      in the default permission mode, not bypass. Inside the container,
      with `~/.claude/settings.json` backed up first, write
      `{"permissions":{"allow":["Bash(touch /tmp/ALLOW-TEST)"]}}` to it,
      start `claude` interactively and ask it to run exactly
      `touch /tmp/ALLOW-TEST`. Expect a permission prompt (the planted
      rule did nothing) with no "always allow" option offered. Restore the
      backup.
- [ ] The Artifact tool is denied. Inside a session, ask: "Publish a
      one-line HTML page as an artifact." Expect Claude to report that
      the tool is blocked by a permission rule, with no prompt offering to
      allow it and no URL produced. Confirm the rule is the managed one
      and not overridable: inside the container, write
      `{"permissions":{"allow":["Artifact"]}}` to `~/.claude/settings.json`
      (backing it up first), repeat the request, expect the same refusal,
      then restore the backup.
- [ ] Postgres version is actually controlled by `POSTGRES_VERSION`.
- [ ] The baked toolchain is present and immutable. Inside the container
      (interactive shell, so `toolchain.sh` has been sourced):
      `erl -noshell -eval 'io:format("~s~n",[erlang:system_info(otp_release)]),halt().'`,
      `elixir --version`, `node --version`, `k6 version` and, if set,
      `ruby --version` all report the versions from `.env.claude`;
      `touch /opt/asdf/x /opt/rvm/x` fails with "Read-only file system";
      `cat /etc/claude-sandbox/toolchain.sh` lists one `ASDF_*_VERSION`
      export per installed tool. Also `docker exec <container> node
      --version` from the host reports the base image's node 22, not the
      asdf one (that path doesn't read bashrc, by design).
- [ ] Nothing the image needs is hidden by the home volume: with the
      container running, `docker run --rm <image> ls /home/node` shows no
      `.rvm`, `.asdf` or `.local/bin` -- everything is in `/opt` and `/etc`.
- [ ] `TMPDIR` is exec-capable: inside the container
      `printf '#!/bin/sh\necho ok\n' > "$TMPDIR/t" && chmod +x "$TMPDIR/t" && "$TMPDIR/t"`
      prints `ok`, while the same against `/tmp/t` fails with "Permission
      denied".
- [ ] Dependencies install from the sandbox against the `:ro` tree. In an
      Elixir project directory: `mix deps.get && mix compile` succeeds and
      writes under `/home/node/mix/`, nothing under `/workspace/code`
      changes (`git status` on the host is clean). In a Ruby project:
      `bundle install` succeeds into `/home/node/.bundle-path`; with a
      deliberately stale `Gemfile.lock` on the host it fails with a
      "frozen" message, not `EROFS`.
- [ ] Both the project `CLAUDE.md` and the personal `CLAUDE.md` take
      effect simultaneously (merge confirmed).
