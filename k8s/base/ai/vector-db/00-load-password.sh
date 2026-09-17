# PostgreSQL entrypoint sources this non-executable file before init.sql.
# Do not enable shell tracing: the variable contains a database credential.
if [ -z "${AI_DB_PASSWORD_FILE:-}" ] || [ ! -r "$AI_DB_PASSWORD_FILE" ]; then
  printf '%s\n' 'AI database password file is missing or unreadable' >&2
  exit 1
fi
AI_DB_PASSWORD="$(cat "$AI_DB_PASSWORD_FILE")"
if [ -z "$AI_DB_PASSWORD" ]; then
  printf '%s\n' 'AI database password file is empty' >&2
  exit 1
fi
export AI_DB_PASSWORD
