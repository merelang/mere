#!/bin/sh
# scripts/live_soundness_check.sh — G-4: no write leaves a read stale.
#
# The other live gates check that the derivation says what it is supposed to
# say, and that the wire carries it. Neither asks the only question that
# matters to someone reading a screen: WHEN A WRITE CHANGES WHAT A READ
# RETURNS, IS THE READER TOLD?
#
# THE ORACLE IS THE DATABASE. For each (write, read) pair, inside one
# transaction that is rolled back:
#
#     read  -> before
#     write
#     read  -> after
#
# `before != after` is ground truth that the read went stale. contrib/db/live's
# `affects` is the claim. Crossing them gives four cells, and only one is a bug:
#
#   changed & claimed      correct -- the reader is woken
#   unchanged & not        correct -- nothing to say
#   unchanged & claimed    WASTEFUL. The cost of table granularity. Counted and
#                          printed, not failed: it wakes a reader that did not
#                          need it, which is slow, not wrong.
#   changed & NOT claimed  UNSOUND. A reader holding a result that is no longer
#                          true, and nothing will ever tell it. This is the
#                          failure the whole idea exists to remove, and the
#                          only cell that fails this gate.
#
# Uses a server that is already running (a CI service container, or one in
# Docker) when there is one, and otherwise starts its own the way mere-blog's
# verify.sh does. Skips only when neither is available.
set -u

MERE=${MERE:-./_build/default/bin/mere.exe}
[ -x "$MERE" ] || { echo "live_soundness: no compiler at $MERE (run dune build)"; exit 1; }
command -v psql >/dev/null 2>&1 || { echo "live_soundness: SKIP (no psql)"; exit 0; }

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

# An already-running server (a CI service container, or one in Docker) is used
# as it is. Otherwise one is started here, the way mere-blog's verify.sh does.
if psql -h "$PGHOST_T" -p "$PGPORT_T" -U "$PGUSER_T" -l >/dev/null 2>&1; then
  :
else
  for t in initdb pg_ctl createdb; do
    command -v "$t" >/dev/null 2>&1 || { echo "live_soundness: SKIP (no server at $PGHOST_T:$PGPORT_T and no $t)"; exit 0; }
  done
  initdb -D "$PGDATA_DIR" -U postgres --auth=trust > "$TMP/initdb.log" 2>&1 \
    || { echo "live_soundness: SKIP (initdb failed: $(sed -n '1p' "$TMP/initdb.log" | cut -c1-70))"; exit 0; }
  pg_ctl -D "$PGDATA_DIR" -o "-p $PGPORT_T -k $PGDATA_DIR -c listen_addresses=127.0.0.1" \
         -l "$PGDATA_DIR/server.log" start > "$TMP/pgstart.log" 2>&1 \
    || { echo "live_soundness: FAIL — postgres did not start"; sed -n '1,5p' "$PGDATA_DIR/server.log"; exit 1; }
  started_own=yes
  i=0
  until psql -h "$PGHOST_T" -p "$PGPORT_T" -U "$PGUSER_T" -l >/dev/null 2>&1; do
    i=$((i + 1)); [ "$i" -gt 100 ] && { echo "live_soundness: FAIL — postgres never accepted"; exit 1; }; sleep 0.1
  done
fi

DB=livetest_$$
createdb -h "$PGHOST_T" -p "$PGPORT_T" -U "$PGUSER_T" "$DB" >/dev/null 2>&1 \
  || psql -h "$PGHOST_T" -p "$PGPORT_T" -U "$PGUSER_T" -d postgres -X -q -c "CREATE DATABASE $DB" >/dev/null 2>&1 \
  || { echo "live_soundness: FAIL — could not create $DB"; exit 1; }

PSQL="psql -h $PGHOST_T -p $PGPORT_T -U $PGUSER_T -d $DB -X -q -t -A"

$PSQL > "$TMP/schema.log" 2>&1 <<'SQL'
CREATE TABLE users    (id serial PRIMARY KEY, username text UNIQUE NOT NULL, pw_hash text NOT NULL);
CREATE TABLE sessions (sid text PRIMARY KEY, username text NOT NULL);
CREATE TABLE posts    (id serial PRIMARY KEY, author text NOT NULL, title text NOT NULL, body text NOT NULL, published boolean NOT NULL DEFAULT false);
CREATE TABLE comments (id serial PRIMARY KEY, post_id integer NOT NULL REFERENCES posts(id) ON DELETE CASCADE, author text NOT NULL, body text NOT NULL);
INSERT INTO users (username, pw_hash) VALUES ('alice','h');
INSERT INTO sessions (sid, username) VALUES ('s1','alice');
INSERT INTO posts (author, title, body, published) VALUES ('alice','first','b',true);
INSERT INTO posts (author, title, body, published) VALUES ('alice','second','b',false);
INSERT INTO comments (post_id, author, body) VALUES (1,'alice','hi');
SQL
grep -qi error "$TMP/schema.log" && { echo "live_soundness: FAIL — schema"; cat "$TMP/schema.log"; exit 1; }

# The statements, held here in the same order test/live/claims.mere holds them.
read_sql() {
  case $1 in
    r_posts_all)  echo "SELECT id, title FROM posts ORDER BY id" ;;
    r_posts_pub)  echo "SELECT id, title FROM posts WHERE published = true ORDER BY id" ;;
    r_post_one)   echo "SELECT id, title FROM posts WHERE id = 1" ;;
    r_comments_1) echo "SELECT id, body FROM comments WHERE post_id = 1 ORDER BY id" ;;
    r_sessions)   echo "SELECT username FROM sessions ORDER BY sid" ;;
    r_users)      echo "SELECT id, username FROM users ORDER BY id" ;;
  esac
}
write_sql() {
  case $1 in
    w_post_ins)    echo "INSERT INTO posts (author, title, body, published) VALUES ('a','t','b',true)" ;;
    w_post_upd)    echo "UPDATE posts SET title = 'changed' WHERE id = 1" ;;
    w_post_del)    echo "DELETE FROM posts WHERE id = 1" ;;
    w_comment_ins) echo "INSERT INTO comments (post_id, author, body) VALUES (1,'a','c')" ;;
    w_session_ins) echo "INSERT INTO sessions (sid, username) VALUES ('s9','alice')" ;;
    w_user_ins)    echo "INSERT INTO users (username, pw_hash) VALUES ('bob','h')" ;;
  esac
}

"$MERE" test/live/claims.mere > "$TMP/claims.txt" 2>"$TMP/claims.err" \
  || { echo "live_soundness: FAIL — claims program"; head -3 "$TMP/claims.err"; exit 1; }
pairs=$(grep -cE '^(w_[a-z_]+) (r_[a-z_0-9]+) (yes|no)$' "$TMP/claims.txt")
[ "$pairs" -eq 36 ] || { echo "live_soundness: FAIL — got $pairs claims, expected 36"; exit 1; }

unsound=0; wasteful=0; correct=0; checked=0
: > "$TMP/report"

while read -r w r claim; do
  case "$w" in w_*) ;; *) continue ;; esac
  rq=$(read_sql "$r"); wq=$(write_sql "$w")
  [ -n "$rq" ] && [ -n "$wq" ] || { echo "live_soundness: FAIL — unknown pair $w/$r (the two lists have drifted)"; exit 1; }
  out=$($PSQL <<SQL
BEGIN;
$rq;
SELECT '---MARK---';
$wq;
$rq;
ROLLBACK;
SQL
)
  before=$(echo "$out" | sed -n '1,/---MARK---/p' | sed '$d')
  after=$(echo "$out" | sed -n '/---MARK---/,$p' | sed '1d')
  checked=$((checked + 1))
  if [ "$before" = "$after" ]; then changed=no; else changed=yes; fi
  if [ "$changed" = yes ] && [ "$claim" = no ]; then
    unsound=$((unsound + 1))
    echo "  UNSOUND  $w -> $r : the result changed and nothing would have said so" >> "$TMP/report"
  elif [ "$changed" = no ] && [ "$claim" = yes ]; then
    wasteful=$((wasteful + 1))
    echo "  wasteful $w -> $r : woken, but the result was the same" >> "$TMP/report"
  else
    correct=$((correct + 1))
  fi
done < "$TMP/claims.txt"

[ "$checked" -eq 36 ] || { echo "live_soundness: FAIL — executed $checked of 36 pairs"; exit 1; }

[ -s "$TMP/report" ] && cat "$TMP/report"
echo "live_soundness: $checked pairs against a real database — $correct exact, $wasteful wasteful, $unsound unsound"
[ "$unsound" -eq 0 ] || { echo "  A read whose result changed with nothing to tell it is the failure this gate exists for."; exit 1; }
exit 0
