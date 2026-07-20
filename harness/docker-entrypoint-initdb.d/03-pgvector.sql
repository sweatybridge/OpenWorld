-- pgvector adds the `vector` type plus similarity-search index access methods
-- (hnsw, ivfflat) for approximate nearest-neighbor queries over embeddings. The
-- .so, control, and install SQL come from the PGDG apt package in the Dockerfile;
-- CREATE EXTENSION registers the type, the distance operators (<->, <#>, <=>),
-- and the index am handlers. No shared_preload_libraries (no background worker).
CREATE EXTENSION IF NOT EXISTS vector;
