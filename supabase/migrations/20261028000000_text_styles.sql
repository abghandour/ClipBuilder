-- Text styles are carried in profile_documents.document_json, alongside
-- caption_styles and tag_styles; the nested decor/shared_style_id fields
-- travel inside the existing JSON payloads. There is no separate brand table
-- or new SQL column in the current schema. Keep the wire descriptor at
-- [document_json] and avoid a redundant column or a schema-version bump.
COMMENT ON COLUMN public.profile_documents.document_json IS
'Portable profile JSON, including text_styles (named decorations and font family), caption_styles and tag_styles. Optional decor/shared_style_id keys preserve old clients.';
