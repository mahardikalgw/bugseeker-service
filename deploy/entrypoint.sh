#!/bin/sh
set -e

# Run pending migrations, then start the server.
bin/bugseeker eval "Bugseeker.Release.migrate()"

exec bin/bugseeker start
