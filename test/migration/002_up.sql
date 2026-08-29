-- Add a slug every post must have.
--
-- Written so it survives a populated table: the column arrives nullable, every
-- existing row is given a value, and only THEN is NOT NULL imposed. The
-- one-line version of this migration -- ALTER TABLE posts ADD COLUMN slug text
-- NOT NULL -- passes on an empty database and cannot be applied to one with
-- rows in it, which is the whole reason this gate seeds first.
ALTER TABLE posts ADD COLUMN slug text;
UPDATE posts SET slug = lower(regexp_replace(coalesce(nullif(title, ''), 'post-' || id), '[^a-zA-Z0-9]+', '-', 'g'));
ALTER TABLE posts ALTER COLUMN slug SET NOT NULL;
