FROM elixir:1.20.5-otp-29-alpine

WORKDIR /action

ENV MIX_ENV=prod

COPY mix.exs ./
COPY lib lib
COPY templates templates
COPY maps maps
COPY zen_penguin.json config.exs ./

RUN mix compile --no-deps-check

ENTRYPOINT ["mix", "run", "--no-deps-check", "-e", "ZenPenguin.CLI.main([])"]
