FROM golang:1.23-bookworm

RUN ln -s /usr/local/go/bin/go /usr/local/bin/go \
  && ln -s /usr/local/go/bin/gofmt /usr/local/bin/gofmt

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    bash \
    bubblewrap \
    ca-certificates \
    coreutils \
    findutils \
    git \
    libgmp10 \
    postgresql-client \
    ripgrep \
    zlib1g \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /workspace
