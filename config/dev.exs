import Config

config :bugseeker, BugseekerWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base: "8fZLAeM1hWMbBF/28GW3Kus37w76QsryT4sgeDT5TbKpBctehH6NcgqpBV9uh/9S",
  watchers: []

config :logger, :default_formatter, format: "[$level] $message\n"

config :phoenix, :stacktrace_depth, 20
config :phoenix, :plug_init_mode, :runtime
