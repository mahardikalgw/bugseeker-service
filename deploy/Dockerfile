# Builder stage
FROM hexpm/elixir:1.18.0-erlang-27.0.0-slim AS build

WORKDIR /app

ENV MIX_ENV=prod

RUN mix local.hex --force && mix local.rebar --force

COPY mix.exs mix.lock ./
COPY config ./config
RUN mix deps.get --only prod && mix deps.compile

COPY lib ./lib
COPY skills ./skills
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

USER codeseeker

ENV PORT=4000 \
    PHX_SERVER=true

EXPOSE 4000

HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
  CMD curl -f http://localhost:4000/healthz || exit 1

CMD ["/opt/codeseeker/bin/codeseeker", "start"]
