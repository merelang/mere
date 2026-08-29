#!/bin/sh
# scripts/migration_check.sh — G-5: a migration must consume every existing row.
#
# MIGRATIONS ARE TESTED ON EMPTY DATABASES. CI creates a fresh one and runs
# them, and mere-blog's verify.sh does exactly that. An empty table accepts
# migrations a populated one refuses -- `ADD COLUMN slug text NOT NULL` is
# valid against zero rows and impossible against four -- so the usual test
# passes on the one input that cannot fail.
#
# So this seeds FIRST. test/migration/001_base.sql carries the shapes a
# migration written against an empty table never meets: a NULL in a nullable
# column, an empty string, and a duplicated value. Then:
#
#   up      every pre-existing row still exists, and has a value for the new
#           column. A migration that drops rows it cannot convert, or leaves
#           them NULL, fails here rather than in production.
#   down    the schema returns to what it was, with the same rows.
#   up again  reapplying reaches the same state -- a migration that is not
#           idempotent under down/up is one that cannot be rolled forward.
#
# THE EMPTY CASE IS RUN TOO, and separately, so the gate can say what it
# actually shows: passing on an empty database is not evidence, and this
# reports both so the difference is visible rather than assumed.
#
# Uses a server that is already running when there is one (a CI service
# container, or Docker), and otherwise starts its own the way mere-blog's
# verify.sh does.
set -u

DIR=test/migration
command -v psql >/dev/null 2>&1 || { echo "migration_check: SKIP (no psql)"; exit 0; }

TMP=$(mktemp -d) || exit 1
started_own=no
PGDATA_DIR="$TMP/pg"
PGPORT_T=${PGPORT_T:-54329}
PGHOST_T=${PGHOST_T:-127.0.0.1}
PGUSER_T=${PGUSER_T:-postgres}
cleanup() {
  [ "$started_own" = yes ] && pg_ctl -D "$PGDATA_DIR" stop -m immediate >/dev/null 2>&1
  rm -rf "$TMP"
}
trap cleanup EXIT

if psql -h "$PGHOST_T" -p "$PGPORT_T" -U "$PGUSER_T" -l >/dev/null 2>&1; then
  :
else
  for t in initdb pg_ctl; do
    command -v "$t" >/dev/null 2>&1 || { echo "migration_check: SKIP (no server at $PGHOST_T:$PGPORT_T and no $t)"; exit 0; }
  done
  initdb -D "$PGDATA_DIR" -U postgres --auth=trust > "$TMP/initdb.log" 2>&1 \
    || { echo "migration_check: SKIP (initdb failed: $(sed -n '1p' "$TMP/initdb.log" | cut -c1-60))"; exit 0; }
  pg_ctl -D "$PGDATA_DIR" -o "-p $PGPORT_T -k $PGDATA_DIR -c listen_addresses=127.0.0.1" \
         -l "$PGDATA_DIR/server.log" start > "$TMP/pgstart.log" 2>&1 \
    || { echo "migration_check: FAIL — postgres did not start"; sed -n '1,5p' "$PGDATA_DIR/server.log"; exit 1; }
  started_own=yes
  i=0
  until psql -h "$PGHOST_T" -p "$PGPORT_T" -U "$PGUSER_T" -l >/dev/null 2>&1; do
    i=$((i + 1)); [ "$i" -gt 100 ] && { echo "migration_check: FAIL — postgres never accepted"; exit 1; }; sleep 0.1
  done
fi

fail=0; checks=0
say() { checks=$((checks + 1)); [ "$2" = "$3" ] || { echo "  FAIL $1: expected [$2] got [$3]"; fail=$((fail + 1)); }; }

mkdb() {
  psql -h "$PGHOST_T" -p "$PGPORT_T" -U "$PGUSER_T" -d postgres -X -q \
    -c "DROP DATABASE IF EXISTS $1" -c "CREATE DATABASE $1" >/dev/null 2>&1
}
q() {  # q <db> <sql>
  psql -h "$PGHOST_T" -p "$PGPORT_T" -U "$PGUSER_T" -d "$1" -X -q -t -A -c "$2" 2>&1
}
runf() { # runf <db> <file> -> prints error text, empty on success
  psql -h "$PGHOST_T" -p "$PGPORT_T" -U "$PGUSER_T" -d "$1" -X -q -v ON_ERROR_STOP=1 -f "$2" 2>&1
}

# ---- populated: the case the usual test never runs -----------------------
DBP=migtest_pop_$$
mkdb "$DBP"
err=$(runf "$DBP" "$DIR/001_base.sql"); say "seed applies" "" "$err"
before=$(q "$DBP" "SELECT count(*) FROM posts")
say "seeded rows" "4" "$before"

err=$(runf "$DBP" "$DIR/002_up.sql")
say "up applies to a POPULATED table" "" "$err"

after=$(q "$DBP" "SELECT count(*) FROM posts")
say "no row lost by the migration" "$before" "$after"
nulls=$(q "$DBP" "SELECT count(*) FROM posts WHERE slug IS NULL")
say "every pre-existing row got a value" "0" "$nulls"
empty=$(q "$DBP" "SELECT count(*) FROM posts WHERE slug = ''")
say "and not an empty one" "0" "$empty"
notnull=$(q "$DBP" "SELECT is_nullable FROM information_schema.columns WHERE table_name='posts' AND column_name='slug'")
say "the constraint is actually on" "NO" "$notnull"

# ---- down, and forward again --------------------------------------------
err=$(runf "$DBP" "$DIR/002_down.sql"); say "down applies" "" "$err"
cols=$(q "$DBP" "SELECT count(*) FROM information_schema.columns WHERE table_name='posts' AND column_name='slug'")
say "down removed the column" "0" "$cols"
rows=$(q "$DBP" "SELECT count(*) FROM posts")
say "down kept every row" "$before" "$rows"
err=$(runf "$DBP" "$DIR/002_up.sql"); say "up applies again after down" "" "$err"
again=$(q "$DBP" "SELECT count(*) FROM posts WHERE slug IS NULL")
say "and still leaves nothing unconverted" "0" "$again"

# ---- empty: reported, so the difference is visible ------------------------
DBE=migtest_empty_$$
mkdb "$DBE"
psql -h "$PGHOST_T" -p "$PGPORT_T" -U "$PGUSER_T" -d "$DBE" -X -q \
  -c "$(sed -n '/CREATE TABLE/,/);/p' "$DIR/001_base.sql")" >/dev/null 2>&1
err_empty=$(runf "$DBE" "$DIR/002_up.sql")
psql -h "$PGHOST_T" -p "$PGPORT_T" -U "$PGUSER_T" -d postgres -X -q \
  -c "DROP DATABASE IF EXISTS $DBP" -c "DROP DATABASE IF EXISTS $DBE" >/dev/null 2>&1

if [ -z "$err_empty" ]; then
  empty_note="the same migration also passes on an empty database, which is what the usual test measures"
else
  empty_note="NOTE: it does not even pass on an empty database"
fi

[ "$checks" -ge 12 ] || { echo "migration_check: FAIL — only $checks checks ran"; exit 1; }
[ "$fail" -eq 0 ] || { echo "migration_check: FAIL — $fail of $checks"; exit 1; }
echo "migration_check: $checks checks against a POPULATED database ($before rows) — $empty_note"
exit 0
