FROM ubuntu:24.04

RUN apt-get update && apt-get install -y squid && apt-get clean

COPY squid.conf /etc/squid/squid.conf

# Fail the image build on a config that squid itself rejects, rather than
# finding out when the per-project stack comes up. Parsing doesn't need
# any of the runtime paths to be writable.
RUN squid -k parse -f /etc/squid/squid.conf

# Foreground, no daemonising; logs go to stdout/stderr per squid.conf.
# The per-project compose file runs this as uid 1000 with a read-only
# root fs, cap_drop ALL and tmpfs on /tmp and /run.
CMD ["squid", "-N", "-f", "/etc/squid/squid.conf"]
