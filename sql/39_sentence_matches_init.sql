-- Creates the empty accumulation target for stage 41's batched INSERT (the matching
-- procedure never creates its own destination table). Idempotent: a rerun must not truncate
-- rows already inserted by an in-progress or prior matching loop, so this only creates the
-- table on first use — CREATE OR REPLACE would wipe stage 42's progress on every retry.
CREATE TABLE IF NOT EXISTS `${work_dataset}.datacite_sentence_matches`
(
  publication_id STRING,
  location       STRING,
  doi_prefixes   STRING,
  text           STRING,
  doibit_tail    STRING,
  doi            STRING
)
CLUSTER BY publication_id;
