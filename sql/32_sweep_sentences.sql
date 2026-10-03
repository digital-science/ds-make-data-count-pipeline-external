-- Sentence explosion: structured fulltext -> one row per sentence/title/table-row with a
-- location label. Locations (esp. availability_* and references_*) are load-bearing
-- downstream: cue-scoring modifiers and reference remapping key off them.
CREATE OR REPLACE TABLE `${work_dataset}.sweep_sentences`
CLUSTER BY publication_id AS
select g.id publication_id, 'abstract_title' location, sect.title.text from `${work_dataset}.sweep_grobid` g, unnest(fulltext.abstract.sections) sect where sect.title.text is not null
union all
select g.id publication_id, 'abstract_sentences', s.text from `${work_dataset}.sweep_grobid` g, unnest(fulltext.abstract.sections) sect, unnest(sect.sentences) s
union all
select g.id publication_id, 'body_titles' location, sect.title.text from `${work_dataset}.sweep_grobid` g, unnest(fulltext.body.sections) sect where sect.title.text is not null
union all
select g.id publication_id, 'body_sentences', s.text from `${work_dataset}.sweep_grobid` g, unnest(fulltext.body.sections) sect, unnest(sect.sentences) s
union all
select g.id publication_id, 'acknowledgement_titles' location, sect.title.text from `${work_dataset}.sweep_grobid` g, unnest(fulltext.acknowledgement.sections) sect where sect.title.text is not null
union all
select g.id publication_id, 'acknowledgement_sentences', s.text from `${work_dataset}.sweep_grobid` g, unnest(fulltext.acknowledgement.sections) sect, unnest(sect.sentences) s
union all
select g.id publication_id, 'annex_titles' location, sect.title.text from `${work_dataset}.sweep_grobid` g, unnest(fulltext.annex.sections) sect where sect.title.text is not null
union all
select g.id publication_id, 'annex_sentences', s.text from `${work_dataset}.sweep_grobid` g, unnest(fulltext.annex.sections) sect, unnest(sect.sentences) s
union all
select g.id publication_id, 'availability_titles' location, sect.title.text from `${work_dataset}.sweep_grobid` g, unnest(fulltext.availability.sections) sect where sect.title.text is not null
union all
select g.id publication_id, 'availability_sentences', s.text from `${work_dataset}.sweep_grobid` g, unnest(fulltext.availability.sections) sect, unnest(sect.sentences) s
union all
select g.id publication_id, 'funding_titles' location, sect.title.text from `${work_dataset}.sweep_grobid` g, unnest(fulltext.funding.sections) sect where sect.title.text is not null
union all
select g.id publication_id, 'funding_sentences', s.text from `${work_dataset}.sweep_grobid` g, unnest(fulltext.funding.sections) sect, unnest(sect.sentences) s
union all
select g.id publication_id, 'notes_sentences', s.text from `${work_dataset}.sweep_grobid` g, unnest(fulltext.notes) n, unnest(n.sentences) s
union all
select g.id publication_id, 'graphics_titles', gr.title from `${work_dataset}.sweep_grobid` g, unnest(fulltext.graphics) gr where gr.title is not null
union all
select g.id publication_id, 'graphics_sentences', s.text from `${work_dataset}.sweep_grobid` g, unnest(fulltext.graphics) gr, unnest(gr.description) s
union all
select g.id publication_id, 'tables_titles', tb.title from `${work_dataset}.sweep_grobid` g, unnest(fulltext.tables) tb where tb.title is not null
union all
select g.id publication_id, 'tables_sentences', s.text from `${work_dataset}.sweep_grobid` g, unnest(fulltext.tables) tb, unnest(tb.description) s
union all
select g.id publication_id, 'tables_rows', col from `${work_dataset}.sweep_grobid` g, unnest(fulltext.tables) tb, unnest(tb.rows) rw, unnest(rw.columns) col
union all
select g.id publication_id, 'references_titles', ref.article_id.doi from `${work_dataset}.sweep_grobid` g, unnest(fulltext.bibliography.references) ref where ref.article_id.doi is not null
union all
select g.id publication_id, 'references_text_titles', ref.title from `${work_dataset}.sweep_grobid` g, unnest(fulltext.bibliography.references) ref where ref.title is not null
union all
select g.id publication_id, 'references_uris', ref.article_id.uri from `${work_dataset}.sweep_grobid` g, unnest(fulltext.bibliography.references) ref where ref.article_id.uri is not null
