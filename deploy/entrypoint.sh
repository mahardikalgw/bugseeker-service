#!/bin/sh
set -e

# Run pending migrations, then start the server.
bin/codeseeker eval "Codeseeker.Release.migrate()"

exec bin/codeseeker start
