-- The schema as shipped, and rows that already exist in it. The seed carries
-- the shapes a migration written against an empty table never meets: a NULL
-- in a nullable column, an empty string, and a value that is not unique.
CREATE TABLE posts (
  id        serial PRIMARY KEY,
  author    text NOT NULL,
  title     text NOT NULL,
  body      text,
  published boolean NOT NULL DEFAULT false
);
INSERT INTO posts (author, title, body, published) VALUES ('alice', 'first',  'hello', true);
INSERT INTO posts (author, title, body, published) VALUES ('alice', 'second', NULL,    false);
INSERT INTO posts (author, title, body, published) VALUES ('bob',   '',       '',      true);
INSERT INTO posts (author, title, body, published) VALUES ('bob',   'first',  'dup',   false);
