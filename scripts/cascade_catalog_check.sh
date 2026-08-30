#!/bin/sh
# scripts/cascade_catalog_check.sh -- what the DDL parser derives, against what
# Postgres says the schema actually is.
#
# `cascades_of` reads foreign keys out of DDL TEXT. That is a parser, and a
# parser's coverage is whatever its author thought of. Twice now it was not
# enough:
#
#   ON DELETE SET NULL / SET DEFAULT were skipped under a note saying they "do
#   not remove rows" -- true, and not the question, since the child's rows
#   change and so does a read of them.
#
#   CREATE TABLE IF NOT EXISTS c made the child `if`, recording a pair between
#   the parent and a table that does not exist. The real child was never
#   widened, so affects_via answered false for a DELETE that empties it. That
#   one was latent rather than live: mere-blog writes IF NOT EXISTS only for
#   its schema_migrations table, which is not in the text it hands the parser.
#   It was waiting for someone to spell the schema proper that way.
#
# Both were found by hand, which is the problem: the next one will not be. So
# the expected answer comes from pg_constraint. Each fixture in
# test/live/cascade_fixtures.mere is created in a real Postgres, the catalog is
# asked which foreign keys exist and what they do, and that is compared to what
# the parser derived from the same text.
#
# WHICH ACTIONS COUNT. A pair means "a write to the parent can change the
# child's rows". From confdeltype / confupdtype: c (CASCADE), n (SET NULL) and
# d (SET DEFAULT) change them; a (NO ACTION) and r (RESTRICT) refuse the write
# instead, so nothing changes and no pair is owed. That mapping is the one
# judgement this file makes; everything else is Postgres's answer.
set -u

MERE=${MERE:-./_build/default/bin/mere.exe}
FIX=test/live/cascade_fixtures.mere
[ -x "$MERE" ] || { echo "cascade_catalog: no compiler at $MERE (run dune build)"; exit 1; }
command -v psql >/dev/null 2>&1 || { echo "cascade_catalog: SKIP (no psql)"; exit 0; }

TMP=$(mktemp -d) || exit 1
started_own=no
PGDATA_DIR="$TMP/pg"
PGPORT_T=${PGPORT_T:-54331}
PGHOST_T=${PGHOST_T:-127.0.0.1}
PGUSER_T=${PGUSER_T:-postgres}
cleanup() {
  [ "$started_own" = yes ] && pg_ctl -D "$PGDATA_DIR" stop -m immediate >/dev/null 2>&1
  rm -rf "$TMP"
}
trap cleanup EXIT INT TERM

if psql -h "$PGHOST_T" -p "$PGPORT_T" -U "$PGUSER_T" -l >/dev/null 2>&1; then
  :
else
  for t in initdb pg_ctl; do
    command -v "$t" >/dev/null 2>&1 || { echo "cascade_catalog: SKIP (no server at $PGHOST_T:$PGPORT_T and no $t)"; exit 0; }
  done
  initdb -D "$PGDATA_DIR" -U postgres --auth=trust > "$TMP/initdb.log" 2>&1 \
    || { echo "cascade_catalog: SKIP (initdb failed: $(sed -n '1p' "$TMP/initdb.log" | cut -c1-70))"; exit 0; }
  pg_ctl -D "$PGDATA_DIR" -o "-p $PGPORT_T -k $PGDATA_DIR -c listen_addresses=127.0.0.1" \
         -l "$PGDATA_DIR/server.log" start > "$TMP/pgstart.log" 2>&1 \
    || { echo "cascade_catalog: FAIL -- postgres did not start"; sed -n '1,5p' "$PGDATA_DIR/server.log"; exit 1; }
  started_own=yes
  i=0
  until psql -h "$PGHOST_T" -p "$PGPORT_T" -U "$PGUSER_T" -l >/dev/null 2>&1; do
    i=$((i + 1)); [ "$i" -gt 100 ] && { echo "cascade_catalog: FAIL -- postgres never accepted"; exit 1; }; sleep 0.1
  done
fi

DB=cascadecat_$$
createdb -h "$PGHOST_T" -p "$PGPORT_T" -U "$PGUSER_T" "$DB" >/dev/null 2>&1 \
  || psql -h "$PGHOST_T" -p "$PGPORT_T" -U "$PGUSER_T" -d postgres -X -q -c "CREATE DATABASE $DB" >/dev/null 2>&1 \
  || { echo "cascade_catalog: FAIL -- could not create $DB"; exit 1; }
PSQL="psql -h $PGHOST_T -p $PGPORT_T -U $PGUSER_T -d $DB -X -q -t -A"

"$MERE" "$FIX" > "$TMP/fix.txt" 2> "$TMP/fix.err" || {
  echo "cascade_catalog: FAIL -- $FIX did not run"; sed -n '1,10p' "$TMP/fix.err"; exit 1; }

declared=$(sed -n 's/^fixtures: //p' "$TMP/fix.txt")
case "$declared" in ''|*[!0-9]*) echo "cascade_catalog: FAIL -- $FIX printed no fixture count"; exit 1 ;; esac

checked=0; bad=0
while IFS= read -r line; do
  case "$line" in "ddl "*) ;; *) continue ;; esac
  name=$(echo "$line" | cut -d' ' -f2)
  ddl=$(echo "$line" | cut -d' ' -f3-)
  derived=$(sed -n "s/^pairs $name //p" "$TMP/fix.txt")
  [ -n "$derived" ] || { echo "cascade_catalog: FAIL -- no pairs line for $name"; exit 1; }

  # A schema per fixture, so one fixture's keys are never another's answer.
  $PSQL -c "DROP SCHEMA IF EXISTS f CASCADE; CREATE SCHEMA f;" >/dev/null 2>&1
  err=$(printf 'SET search_path TO f;\n%s\n' "$ddl" | $PSQL 2>&1 >/dev/null)
  if [ -n "$err" ]; then
    echo "cascade_catalog: FAIL -- Postgres refused the $name fixture, so there is"
    echo "  nothing to compare against. The fixture is this repo's, not the parser's:"
    echo "$err" | sed 's/^/    /' | head -3
    exit 1
  fi

  # THE EXPECTED SET, FROM THE CATALOG. c/n/d change the child's rows; a/r
  # refuse the parent's write instead.
  expected=$($PSQL <<SQL
SELECT coalesce(string_agg(pair, ',' ORDER BY pair), '-') FROM (
  SELECT DISTINCT cp.relname::text || '>' || cc.relname::text AS pair
  FROM pg_constraint con
  JOIN pg_class cc ON cc.oid = con.conrelid
  JOIN pg_class cp ON cp.oid = con.confrelid
  JOIN pg_namespace n ON n.oid = con.connamespace
  WHERE con.contype = 'f' AND n.nspname = 'f'
    AND (con.confdeltype IN ('c','n','d') OR con.confupdtype IN ('c','n','d'))
) q;
SQL
)
  got=$(echo "$derived" | tr ',' '\n' | sort | paste -sd, - )
  want=$(echo "$expected" | tr ',' '\n' | sort | paste -sd, - )
  checked=$((checked + 1))
  if [ "$got" != "$want" ]; then
    echo "cascade_catalog: FAIL -- $name"
    echo "    Postgres says: $want"
    echo "    cascades_of  : $got"
    echo "    DDL: $ddl"
    bad=$((bad + 1))
  fi
done < "$TMP/fix.txt"

[ "$checked" -eq "$declared" ] || {
  echo "cascade_catalog: FAIL -- compared $checked of the $declared fixtures declared"; exit 1; }
[ "$bad" -eq 0 ] || exit 1
echo "cascade_catalog: $checked schemas built in Postgres — the DDL parser agrees with pg_constraint on every one"
