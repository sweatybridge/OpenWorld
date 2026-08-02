-- inbound Telegram media: poll_messages photo/video extraction, attachment
-- deferral marker, store_inbound_attachment's fail path (ffmpeg.hls raises
-- on an unreachable URL → BEGIN…EXCEPTION clears pending and appends the
-- note, no RAISE escapes), fail_inbound_attachment, and _message_for_openai's
-- text/fallback behaviour.
--
-- The download happy path needs ffmpeg.hls(url of a reachable media file) +
-- network, so it lives in the integration suite; here we exercise the pure
-- pieces (poll extraction, the pending marker, the fail note, the
-- multimodal-inline fallback). Fixtures: primary=agent 1, chat CZ1,
-- telegram user 9001.
\set ON_ERROR_STOP on
BEGIN;
SELECT no_plan();

-- Bind the primary agent context for RLS-sensitive calls below.
SELECT set_config('ow.current_agent_id', '1', true);
SELECT set_config('ow.current_chat_id', 'CZ1', true);
SELECT ow.configure_telegram('primary', 'TOK', 'CZ1');

-- Helper: build a Telegram getUpdates envelope for one message with a chosen
-- update_id and message body.
CREATE OR REPLACE FUNCTION pgtap_test.envelope(uid bigint, m jsonb)
RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
  SELECT jsonb_build_object(
    'status', 200,
    'body', jsonb_build_object('ok', true, 'result',
      jsonb_build_array(jsonb_build_object('update_id', uid, 'message', m)))
  )
$$;

-- ===== poll_messages: photo-only (no caption) is accepted ====================
-- A photo array with three sizes; poll must pick the largest file_size,
-- mark the message attachment_pending, accept it despite the empty caption,
-- and emit exactly one downloads[] entry.
DO $$
DECLARE
  v_res jsonb;
  v_id bigint;
  v_content text;
  v_pending boolean;
  v_meta_kind text;
  v_meta_file_id text;
  v_dl_kind text;
  v_dl_file_id text;
BEGIN
  SELECT ow.poll_messages('primary', pgtap_test.envelope(100, jsonb_build_object(
    'message_id', 42,
    'date', 1700000000,
    'chat', jsonb_build_object('id', 'CZ1'),
    'from', jsonb_build_object('id', '9001', 'first_name', 'Alice'),
    'photo', jsonb_build_array(
      jsonb_build_object('file_id','f0','file_unique_id','u0','width',160,'height',120,'file_size',1000),
      jsonb_build_object('file_id','f1','file_unique_id','u1','width',800,'height',600,'file_size',30000),
      jsonb_build_object('file_id','f2','file_unique_id','u2','width',1280,'height',720,'file_size',60000)
    )
  ))) INTO v_res;

  ASSERT (v_res->>'accepted') = '1',                                                     'photo-only accepted';
  ASSERT (v_res->>'ignored')  = '0',                                                    'nothing ignored';
  ASSERT coalesce(jsonb_array_length(v_res->'downloads'), -1) = 1,                      'one downloads entry';
  v_dl_kind    := v_res->'downloads'->0->>'kind';
  v_dl_file_id := v_res->'downloads'->0->'meta'->>'file_id';
  ASSERT v_dl_kind = 'photo',     'downloads kind photo';
  ASSERT v_dl_file_id = 'f2',      'downloads meta file_id is largest';

  SELECT id, content,
         coalesce((payload->>'attachment_pending')::boolean, false),
         payload->'attachment_meta'->>'kind',
         payload->'attachment_meta'->>'file_id'
    INTO v_id, v_content, v_pending, v_meta_kind, v_meta_file_id
    FROM ow.messages
    WHERE agent_id = 1 AND (payload #>> '{telegram_update,update_id}') = '100';
  ASSERT v_id IS NOT NULL,             'message row inserted';
  ASSERT v_pending IS TRUE,            'attachment_pending marker set';
  ASSERT v_meta_kind = 'photo',        'meta kind photo';
  ASSERT v_meta_file_id = 'f2',        'meta file_id is largest';
  ASSERT v_content LIKE '[telegram 100] [photo %]', 'placeholder content emitted';
END $$;

-- ===== poll_messages: video + caption is accepted ===========================
DO $$
DECLARE
  v_res jsonb;
  v_id bigint;
  v_pending boolean;
  v_kind text;
  v_mime text;
  v_duration text;
  v_content text;
BEGIN
  SELECT ow.poll_messages('primary', pgtap_test.envelope(101, jsonb_build_object(
    'message_id', 43,
    'date', 1700000001,
    'chat', jsonb_build_object('id', 'CZ1'),
    'from', jsonb_build_object('id', '9001'),
    'caption', 'clip caption',
    'video', jsonb_build_object(
      'file_id', 'vid1', 'file_unique_id', 'vu1',
      'width', 1280, 'height', 720, 'duration', 5,
      'mime_type', 'video/mp4', 'file_name', 'clip.mp4',
      'file_size', 1234567
    )
  ))) INTO v_res;

  ASSERT (v_res->>'accepted') = '1', 'video+caption accepted';
  ASSERT coalesce(jsonb_array_length(v_res->'downloads'), -1) = 1, 'one downloads entry for video';
  ASSERT (v_res->'downloads'->0->>'kind') = 'video', 'downloads kind video';

  SELECT id,
         coalesce((payload->>'attachment_pending')::boolean, false),
         payload->'attachment_meta'->>'kind',
         payload->'attachment_meta'->>'mime_type',
         payload->'attachment_meta'->>'duration',
         content
    INTO v_id, v_pending, v_kind, v_mime, v_duration, v_content
    FROM ow.messages
    WHERE agent_id = 1 AND (payload #>> '{telegram_update,update_id}') = '101';
  ASSERT v_id IS NOT NULL, 'video row inserted';
  ASSERT v_pending IS TRUE, 'video attachment_pending marker';
  ASSERT v_kind = 'video', 'meta kind video';
  ASSERT v_mime = 'video/mp4', 'meta mime_type preserved';
  ASSERT v_duration = '5', 'meta duration preserved';
  ASSERT v_content LIKE '[telegram 101] clip caption', 'caption-as-content kept';
END $$;

-- ===== poll_messages: sticker-only is ignored (no text) ======================
DO $$
DECLARE
  v_res jsonb;
BEGIN
  SELECT ow.poll_messages('primary', pgtap_test.envelope(102, jsonb_build_object(
    'message_id', 50,
    'chat', jsonb_build_object('id', 'CZ1'),
    'from', jsonb_build_object('id', '9001'),
    'sticker', jsonb_build_object('file_id', 'st1', 'width', 512, 'height', 512)
  ))) INTO v_res;
  ASSERT (v_res->>'ignored') = '1', 'sticker (no text/file) is ignored';
  ASSERT coalesce(jsonb_array_length(v_res->'downloads'), -1) = 0, 'no downloads for sticker';
END $$;

-- ===== poll_messages: document-only is ignored (now unsupported) =============
-- A document with no caption has no text and is not a supported file: ignored.
DO $$
DECLARE
  v_res jsonb;
  v_count bigint;
BEGIN
  SELECT ow.poll_messages('primary', pgtap_test.envelope(103, jsonb_build_object(
    'message_id', 51,
    'chat', jsonb_build_object('id', 'CZ1'),
    'from', jsonb_build_object('id', '9001'),
    'document', jsonb_build_object('file_id', 'doc1', 'file_name', 'r.pdf',
                                   'mime_type', 'application/pdf', 'file_size', 9999)
  ))) INTO v_res;
  ASSERT (v_res->>'ignored') = '1', 'document-only (no caption) is ignored';
  ASSERT coalesce(jsonb_array_length(v_res->'downloads'), -1) = 0, 'no downloads for document';

  SELECT count(*) INTO v_count FROM ow.messages
    WHERE agent_id = 1 AND payload #>> '{telegram_update,update_id}' = '103';
  ASSERT v_count = 0, 'no message row inserted for an ignored document';
END $$;

-- A document WITH a caption is accepted as text-only (the caption is the
-- content). attachment_meta / attachment_pending must NOT be set on it.
DO $$
DECLARE
  v_res jsonb;
  v_payload jsonb;
  v_content text;
BEGIN
  SELECT ow.poll_messages('primary', pgtap_test.envelope(104, jsonb_build_object(
    'message_id', 52,
    'chat', jsonb_build_object('id', 'CZ1'),
    'from', jsonb_build_object('id', '9001'),
    'caption', 'a report',
    'document', jsonb_build_object('file_id', 'doc2', 'file_name', 'r.pdf',
                                   'mime_type', 'application/pdf', 'file_size', 9999)
  ))) INTO v_res;
  ASSERT (v_res->>'accepted') = '1', 'document-with-caption accepted as text';
  ASSERT coalesce(jsonb_array_length(v_res->'downloads'), -1) = 0, 'documents emit no downloads';

  SELECT payload, content INTO v_payload, v_content FROM ow.messages
    WHERE agent_id = 1 AND payload #>> '{telegram_update,update_id}' = '104';
  ASSERT NOT (v_payload ? 'attachment_pending'), 'document row has no attachment_pending';
  ASSERT NOT (v_payload ? 'attachment_meta'),    'document row has no attachment_meta';
  ASSERT v_content LIKE '[telegram 104] a report', 'document caption kept as content';
END $$;

-- ===== fail_inbound_attachment: clear pending + append note ==================
DO $$
DECLARE
  v_msg_id bigint;
  v_payload jsonb;
  v_content text;
BEGIN
  INSERT INTO ow.messages(agent_id, role, content, payload, channel, chat_id)
    VALUES (1, 'user', '[telegram 200] [photo 8x8]',
            jsonb_build_object('attachment_pending', true,
              'attachment_meta', jsonb_build_object('kind','photo','file_id','fid')),
            'telegram', 'CZ1')
    RETURNING id INTO v_msg_id;

  PERFORM ow.fail_inbound_attachment('primary', v_msg_id, 'connection refused');

  SELECT payload, content INTO v_payload, v_content
    FROM ow.messages WHERE id = v_msg_id;
  ASSERT NOT (v_payload ? 'attachment_pending'), 'fail clears attachment_pending';
  ASSERT v_content LIKE '%[attachment download failed: connection refused]%',
    'fail appends the note to content';
END $$;

-- ===== store_inbound_attachment: unreachable URL clears pending =============
-- ffmpeg.hls raises on a refused connection; store must catch it, delegate to
-- fail_inbound_attachment in-place, and never RAISE (rolling back the
-- un-blocking UPDATE would leave the message stuck pending). This exercises
-- the VIDEO path (kind=video → ffmpeg.hls(file_url)).
DO $$
DECLARE
  v_msg_id bigint;
  v_stored text;
  v_payload jsonb;
  v_content text;
BEGIN
  INSERT INTO ow.messages(agent_id, role, content, payload, channel, chat_id)
    VALUES (1, 'user', '[telegram 201] [video 2x2]',
            jsonb_build_object('attachment_pending', true,
              'attachment_meta', jsonb_build_object('kind','video','file_id','fid','mime_type','video/mp4')),
            'telegram', 'CZ1')
    RETURNING id INTO v_msg_id;

  SELECT ow.store_inbound_attachment('primary', v_msg_id,
    jsonb_build_object('kind','video','file_id','fid','mime_type','video/mp4'),
    'http://127.0.0.1:1/never-reaches.mp4', 2.0, NULL) INTO v_stored;

  ASSERT NOT v_stored IS NULL, 'store returns (does not RAISE) on ffmpeg.hls failure';
  ASSERT (v_stored::jsonb->>'ok') = 'false', 'store reports ok=false on failure';

  SELECT payload, content INTO v_payload, v_content
    FROM ow.messages WHERE id = v_msg_id;
  ASSERT NOT (v_payload ? 'attachment_pending'), 'store-fail clears attachment_pending';
  ASSERT v_content LIKE '%[attachment download failed: ffmpeg.hls: %]',
    'store-fail leaves the ffmpeg.hls fail note appended to content';
END $$;

-- ===== store_inbound_attachment: photo download failure clears pending =======
-- Photo path: a non-2xx p_photo_http_response → store raises internally →
-- caught → fail note with the 'photo download: ' prefix; no RAISE escapes.
DO $$
DECLARE
  v_msg_id bigint;
  v_stored text;
  v_payload jsonb;
  v_content text;
BEGIN
  INSERT INTO ow.messages(agent_id, role, content, payload, channel, chat_id)
    VALUES (1, 'user', '[telegram 202] [photo 1x1]',
            jsonb_build_object('attachment_pending', true,
              'attachment_meta', jsonb_build_object('kind','photo','file_id','fid','mime_type','image/jpeg')),
            'telegram', 'CZ1')
    RETURNING id INTO v_msg_id;

  SELECT ow.store_inbound_attachment('primary', v_msg_id,
    jsonb_build_object('kind','photo','file_id','fid','mime_type','image/jpeg'),
    NULL, 2.0, jsonb_build_object('status', 500, 'body', '', 'ok', false)) INTO v_stored;

  ASSERT (v_stored::jsonb->>'ok') = 'false', 'photo-download fail reports ok=false';
  SELECT payload, content INTO v_payload, v_content
    FROM ow.messages WHERE id = v_msg_id;
  ASSERT NOT (v_payload ? 'attachment_pending'), 'photo-download fail clears attachment_pending';
  ASSERT v_content LIKE '%[attachment download failed: photo download: %]',
    'photo-download fail leaves the photo fail note appended to content';
END $$;

-- ===== store_inbound_attachment: photo happy path stores raw bytes ===========
-- A 200 http_response with a real 1x1 PNG as base64 body → store inserts the
-- RAW image bytes as a single segment, writes attachment.playlist_id, clears
-- pending. _message_for_openai then base64-encodes s.data directly (no
-- ffmpeg.thumbnail). Verifiable in pgTAP because no network/ffmpeg.hls is used.
DO $$
DECLARE
  v_msg_id bigint;
  v_stored text;
  v_payload jsonb;
  v_pid bigint;
  v_seg_bytes bytea;
  v_png text := '89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c4890000000d49444154789c63000100000005000100c0e9080a0000000049454e44ae426082';
BEGIN
  INSERT INTO ow.messages(agent_id, role, content, payload, channel, chat_id)
    VALUES (1, 'user', '[telegram 203] [photo 1x1]',
            jsonb_build_object('attachment_pending', true,
              'attachment_meta', jsonb_build_object('kind','photo','file_id','fid','mime_type','image/png')),
            'telegram', 'CZ1')
    RETURNING id INTO v_msg_id;

  SELECT ow.store_inbound_attachment('primary', v_msg_id,
    jsonb_build_object('kind','photo','file_id','fid','mime_type','image/png'),
    NULL, 2.0, jsonb_build_object('status', 200, 'ok', true,
      'body', encode(decode(v_png, 'hex'), 'base64'),
      'encoding', 'base64')) INTO v_stored;

  ASSERT (v_stored::jsonb->>'ok') = 'true', 'photo happy path reports ok=true';
  SELECT payload INTO v_payload FROM ow.messages WHERE id = v_msg_id;
  ASSERT NOT (v_payload ? 'attachment_pending'), 'photo happy path clears pending';
  ASSERT (v_payload->'attachment'->>'playlist_id') IS NOT NULL, 'photo happy path writes playlist_id';
  v_pid := (v_payload->'attachment'->>'playlist_id')::bigint;

  -- The segment data IS the raw PNG (no mpegts wrapping): the same bytes we
  -- uploaded. _message_for_openai will base64-encode s.data directly.
  SELECT data INTO v_seg_bytes FROM ffmpeg.hls_segments
    WHERE playlist_id = v_pid ORDER BY segment_index LIMIT 1;
  ASSERT v_seg_bytes = decode(v_png, 'hex'),
    'photo segment stores the raw image bytes verbatim (no ffmpeg.hls wrapping)';
END $$;

-- ===== _message_for_openai: text fallbacks ===================================
-- With p_multimodal/p_inline both false, OR when the message has no
-- attachment, OR when the attachment has no playlist_id yet (still pending /
-- download failed) → content stays a plain-text string, never a multimodal
-- array. (The positive path — emitting image_url entries per segment — needs
-- valid video segment bytes and is exercised end-to-end against the live DB.)
SELECT set_config('ow.current_agent_id', '1', true);

DO $$
DECLARE
  v_msg ow.messages%ROWTYPE;
  v jsonb;
BEGIN
  -- a normal user text message: no attachment
  v_msg := row(1, 1, 'user', 'hello', '{}'::jsonb, 'telegram', 'CZ1', NULL, now())::ow.messages;
  v := ow._message_for_openai(v_msg, true, true);
  ASSERT jsonb_typeof(v->'content') = 'string', 'no-attachment: content stays a string';

  -- a user message with an attachment_pending payload (download not yet
  -- resolved): there is no `attachment` key, only `attachment_pending`
  v_msg.payload := jsonb_build_object('attachment_pending', true,
    'attachment_meta', jsonb_build_object('kind','photo'));
  v := ow._message_for_openai(v_msg, true, true);
  ASSERT jsonb_typeof(v->'content') = 'string', 'pending attachment (no playlist_id): content stays a string';

  -- multimodal off → never inline (even with an attachment.playlist_id)
  v_msg.payload := jsonb_build_object('attachment',
    jsonb_build_object('kind','photo','playlist_id',12345));
  v := ow._message_for_openai(v_msg, false, true);
  ASSERT jsonb_typeof(v->'content') = 'string',
    'p_multimodal=false: content stays a string';

  -- inline off → never inline
  v := ow._message_for_openai(v_msg, true, false);
  ASSERT jsonb_typeof(v->'content') = 'string',
    'p_inline=false: content stays a string';

  -- attachment with kind=document (not in the photo/video set) → never inlined
  v_msg.payload := jsonb_build_object('attachment',
    jsonb_build_object('kind','document','playlist_id',12345));
  v := ow._message_for_openai(v_msg, true, true);
  ASSERT jsonb_typeof(v->'content') = 'string',
    'document attachment: content stays a string';

  -- attachment with photo kind but no playlist_id yet → never inlined
  v_msg.payload := jsonb_build_object('attachment',
    jsonb_build_object('kind','photo'));
  v := ow._message_for_openai(v_msg, true, true);
  ASSERT jsonb_typeof(v->'content') = 'string',
    'photo attachment with no playlist_id: content stays a string';
END $$;

-- ===== object presence =======================================================
SELECT ok(to_regprocedure('ow.store_inbound_attachment(text,bigint,jsonb,text,float8,jsonb)') IS NOT NULL,
  'ow.store_inbound_attachment(text,bigint,jsonb,text,float8,jsonb) exists');
SELECT ok(to_regprocedure('ow.fail_inbound_attachment(text,bigint,text)') IS NOT NULL,
  'ow.fail_inbound_attachment(text,bigint,text) exists');
SELECT ok(to_regprocedure('ow.start_inbound_downloads(text,jsonb)') IS NOT NULL,
  'ow.start_inbound_downloads(text,jsonb) exists');
SELECT ok(to_regprocedure('ow.download_inbound_file_future(text,bigint,text,text,jsonb)') IS NOT NULL,
  'ow.download_inbound_file_future(text,bigint,text,text,jsonb) exists');
SELECT ok(to_regprocedure('ow._telegram_file_url(text)') IS NOT NULL,
  'ow._telegram_file_url(text) exists');

SELECT * FROM finish();
ROLLBACK;