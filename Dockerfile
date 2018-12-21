FROM debian:stretch-slim

# Install Unison from source with inotify support + remove compilation tools
ARG UNISON_VERSION=2.48.4

RUN apt-get update && apt-get install -y curl inotify-tools build-essential ocaml-nox ctags

RUN curl -L https://github.com/bcpierce00/unison/archive/$UNISON_VERSION.tar.gz | tar zxv -C /tmp && \
    cd /tmp/unison-${UNISON_VERSION} && \
    sed -i -e 's/GLIBC_SUPPORT_INOTIFY 0/GLIBC_SUPPORT_INOTIFY 1/' src/fsmonitor/linux/inotify_stubs.c && \
    make UISTYLE=text NATIVE=true STATIC=true && \
    cp src/unison src/unison-fsmonitor /usr/local/bin && \
    rm -rf /tmp/unison-${UNISON_VERSION}

RUN apt-get remove -y build-essential ocaml-nox
RUN apt-get install -y procps

ENV HOME="/root" \
    UNISON_USER="root" \
    UNISON_GROUP="root" \
    UNISON_UID="0" \
    UNISON_GID="0"

# Copy the bg-sync script into the container.
COPY sync.sh /usr/local/bin/bg-sync
RUN chmod +x /usr/local/bin/bg-sync

CMD ["bg-sync"]
