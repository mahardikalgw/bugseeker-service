# Builder stage
FROM hexpm/elixir:1.18.4-erlang-27.3.4.16-debian-bookworm-20260803-slim AS build

WORKDIR /app

ENV MIX_ENV=prod

RUN mix local.hex --force && mix local.rebar --force

COPY mix.exs mix.lock ./
COPY config ./config
RUN mix deps.get --only prod && mix deps.compile

COPY lib ./lib
COPY priv ./priv
COPY .formatter.exs ./

RUN mix compile --warnings-as-errors && mix release

# Runtime stage
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
      libssl3 libstdc++6 libncurses6 ca-certificates curl \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --create-home --shell /bin/bash codeseeker

WORKDIR /opt/codeseeker

COPY --from=build /app/_build/prod/rel/codeseeker ./

# Self-migrates on boot (Postgres must be reachable and DATABASE_URL set).
COPY deploy/entrypoint.sh ./bin/entrypoint.sh
RUN chmod +x ./bin/entrypoint.sh

USER codeseeker

ENV PORT=4000 \
    PHX_SERVER=true

EXPOSE 4000

HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
  CMD curl -f http://localhost:4000/healthz || exit 1

CMD ["/opt/codeseeker/bin/entrypoint.sh"]
