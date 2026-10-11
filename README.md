# Claude Code sandbox template

Shared base for running Claude Code in an isolated container per project:
Node/Ruby/Rust/Elixir tooling (RVM, asdf, mise) plus an ephemeral Postgres
sibling, on an `internal` Docker network whose only way out is a squid
proxy with a destination allowlist, non-root, `cap_drop: ALL`, `read_only`
root fs.

## One-time host setup

### SELinux (required once per machine)

Docker's `:Z` mount flag only relabels a bind mount's contents at the
moment the container *starts* -- a file added to the host directory while
the container keeps running isn't covered, and SELinux denies the
container access to it until something re-triggers a relabel. Fix this
once per host with a persistent file-context rule instead of relying on
`:Z`:

```bash
sudo dnf install -y policycoreutils-python-utils     # provides semanage
sudo semanage fcontext -a -t container_file_t "<parent dir of your repos>(/.*)?"
sudo restorecon -R -v "<parent dir of your repos>"
```

This has to be re-applied if that parent directory path ever changes.
The compose files in this template deliberately use plain `:ro` (no `:Z`)
on the code mount, relying on this host-side rule instead.

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
   names and the host repo path in the code mount.
3. Fill in `.env.claude`: `PROJECT_NET_OCTET` (must be unique among
   projects running at the same time -- start at 0 and increment per
   additional project), Postgres credentials/version, and the path to
   your personal CLAUDE.md. Never commit this file.
4. `docker compose --env-file .env.claude -f docker-compose.claude.yml up -d`

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

## Postgres

Ephemeral by design: `/var/lib/postgresql/data` is `tmpfs`, so data resets
every time the Postgres sibling container is recreated. No published
ports -- reachable only from the claude container over the internal
`anthropic_containers` network, by IP (DNS on that network only resolves
`anthropic.com`/`claude.ai`, so service-name resolution doesn't work here
-- address Postgres by its static `ipv4_address`, matched to `PGHOST`).

## Updating Claude Code

There's no self-update inside the container, deliberately. The Dockerfile's
`npm install -g @anthropic-ai/claude-code` floats to latest at *build*
time, so to pick up a newer version: rebuild the image and recreate the
container (`docker compose --env-file .env.claude -f
docker-compose.claude.yml up -d --build`).

Letting Claude Code update itself at runtime would mean opening egress to
npm's registry (`registry.npmjs.org`) -- a DNS allowlist addition, and
dropping the pinned-IP leg of the proxy ACL for that destination, since
the registry is CDN-backed with rotating IPs -- plus a writable volume
over `/usr/local/share/npm-global`, which is currently baked read-only
into the image layer. That's a materially bigger, harder-to-reason-about
trust boundary than the three Anthropic hostnames at one pinned IP this
setup allows today, for a problem that a rebuild already solves. Same
philosophy as the native build deps: the fix path is
edit-Dockerfile/rebuild, not live-patch.

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

## Residual risk

- The outbox is the deliberate, reviewed exfiltration path -- its value is
  that nothing leaves without your `docker cp`, not that it's leak-proof.
- Per-tool volumes (home/RVM/asdf/mise) persist across recreates of that
  *project's* container only -- no cross-project sharing, but a
  compromised session could still plant something in a dotfile/shim that
  survives to the next session of the same project.
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
- [ ] A file added to the host repo after container start is visible
      inside the container without any manual relabel/chmod step.
- [ ] A file written to the outbox volume comes out cleanly via `docker cp`.
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
      psql -c 'select 1'                                                        # Postgres on-subnet
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
- [ ] Postgres version is actually controlled by `POSTGRES_VERSION`.
- [ ] Both the project `CLAUDE.md` and the personal `CLAUDE.md` take
      effect simultaneously (merge confirmed).
