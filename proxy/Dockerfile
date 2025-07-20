FROM ubuntu:24.04

RUN apt-get update && apt-get install -y squid && apt-get clean

COPY squid.conf /etc/squid/squid.conf

CMD ["squid", "-N", "-f", "/etc/squid/squid.conf"]
