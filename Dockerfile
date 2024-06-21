FROM rust:1-slim-bookworm
WORKDIR /app
COPY src src
COPY Cargo.lock Cargo.lock
COPY Cargo.toml Cargo.toml
RUN cargo install --path .
STOPSIGNAL SIGINT
ENTRYPOINT [ "benchmark-envoy" ]