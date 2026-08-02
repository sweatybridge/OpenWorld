# Inbound Telegram Media Design

Status: **plan** (not yet implemented)
Depends on: pg_durable v0.2.5 (`$resp.*` dot notation in node SQL) + pg_ffmpeg
(`ffmpeg.hls(url, segment_duration)`, `ffmpeg.thumbnail(bytea, double
precision, text)`)

## Goal

Accept photos and videos sent to the bot, ingest their bytes durably via
`ffmpeg.hls` (which fetches the Telegram file URL itself and stores HLS
segments), reference the result on the message row by a small `playlist_id`,
and let the agent see photos and videos (multimodal models only). Today such updates are
**silently ignored**: `ow.poll_messages` requires non-empty `text`/`caption`,
so a photo with no caption never reaches `ow.messages` at all.

## Background

Telegram file delivery is two steps:

1. `getUpdates` returns a `message` that may carry `photo` (an array of
   `PhotoSize` thumbnails — the last/largest is the full image) or `video`
   (`file_id`, `file_name`, `mime_type`, `file_size`, `width`, `height`,
   `duration` — `mime_type` is `video/mp4` when absent). Neither carries bytes.
2. `getFile(file_id)` returns `file_path`; the bytes are then at
   `<api_base>/file/bot<token>/<file_path>`. Bot downloads are capped at
   **20 MB** by Telegram.

pg_ffmpeg makes step 2 usable as a durable ingest: `ffmpeg.hls(url,
segment_duration)` fetches a remote source itself and stores its HLS segments
in `ffmpeg.hls_playlists` / `ffmpeg.hls_segments`, returning a `playlist_id`.
The URL argument interpolates `$var` references, so a `file_path` obtained in
one node feeds the ingest URL of the next. Bytes never touch `ow.messages`.

## Design overview

Inbound files follow the same pattern as tool calls and outbound sends: the
poll stays one node; each file download is its own **one-shot durable
instance** (`ow:download:<message_id>`), started from a dedicated graph node.
Downloads are therefore independently retryable and visible in the dashboard.

```
getUpdates ─▶ poll_messages ─▶ start_inbound_downloads ─▶ df.start × N files
                                                          │
                    ow:download:<msg_id> instance graph: │
                    getFile ─▶ ok? ─▶ build file_url ─▶ store (ffmpeg.hls + persist playlist_id) ─▶ start agent loop
                              └─ no ─▶ fail_inbound_attachment ───────────────────────────────────▶ start agent loop
```

The agent loop is **deferred** while an attachment is pending, so the model
never answers "I can't see the photo/video" before the playlist is built.

## Changes

### 1. `ow.poll_messages` (23-OpenWorld-telegram.sql)

- Extract file metadata per update:
  - `photo`: pick the largest `PhotoSize` (max of `file_size`, else
    `width*height`); kind `photo`, mime default `image/jpeg`.
  - `video`: take it as-is; kind `video`, mime from Telegram (default
    `video/mp4`), filename/dimensions/duration preserved.
  - Other media (voice/audio/document/sticker/…) remain ignored for now.
- Accept filter becomes: non-empty text/caption **OR** a supported file
  (`photo` or `video`).
- Content for a file-only message is a placeholder:
  `[telegram <update_id>] [photo 1280x720]` /
  `[telegram <update_id>] [video clip.mp4 1280x720 (video/mp4)]`.
  A caption, when present, is used as today.
- Inserted payload gains:
  - `attachment_meta`: `{kind, file_id, file_unique_id, file_size, mime_type,
    filename, width, height, duration}`
  - `attachment_pending: true` — the trigger deferral marker (§3).
- Return value gains a `downloads` array (one entry per accepted file, keyed
  by `update_id`) alongside the existing `{accepted, ignored, error}`.
- Stays free of `df.start` so it remains unit-testable in pgTAP (mirrors the
  `start_tool_calls`/`await_tool_calls` split).

### 2. Inbox graph (30-OpenWorld-durable.sql, `ensure_telegram_inbox_loop`)

One added node after the poll; the poll result is now named:

```
... ~> 'SELECT ow.poll_messages(..., $resp::jsonb)::jsonb AS result' |=> 'poll'
    ~> 'SELECT ow.start_inbound_downloads(..., $poll::jsonb)::text AS downloads'
```

### 3. Trigger deferral (30-OpenWorld-durable.sql, `after_user_message_loop`)

If the candidate trigger row has `payload.attachment_pending = true`, the
trigger returns without starting the loop (and without the typing indicator).
The download instance starts the loop when the `playlist_id` (or the failure
note) is written. A mixed batch (text + photo/video) defers as one unit —
the text waits ~1–2 s for the media, which is the desired behaviour anyway.

### 4. Download instance graph (`ow.download_inbound_file_future`)

Built per file with `file_id`/meta baked in (like `send_message_future` bakes
message context; self-binds the agent GUC):

```
df.http(getFile, 'POST', {file_id}) |=> 'meta'
~> df.if('SELECT $meta.ok AND (ow._http_body_json($meta::jsonb)->>''ok'')::boolean',
     'SELECT ow._telegram_file_url() || ow._http_body_json($meta::jsonb) #>> ''{result,file_path}'' AS url' |=> 'url'
     ~> 'SELECT ow.store_inbound_attachment(..., $url::text, 2.0)::text AS stored'
     ~> 'SELECT ow.start_agent_loop(...)::text AS loop_id',
     'SELECT ow.fail_inbound_attachment(...)::text AS failed'
     ~> 'SELECT ow.start_agent_loop(...)::text AS loop_id')
```

- The fetch is delegated to `ffmpeg.hls`: pg_ffmpeg downloads the URL **itself**
  and stores the segments durably in `ffmpeg.hls_playlists` /
  `ffmpeg.hls_segments`. There is no `df.http` GET node and **no bytes on
  `ow.messages`** — the message row only ever holds the small `playlist_id`
  (see §5).
- New helper `ow._telegram_file_url(slug)` → `<api_base>/file/bot<token>/`
  (mirrors `_telegram_api_url`); the `file_path` tail interpolates at
  execution.
- `start_agent_loop` resolves `requesting_user_id` inline from the stored
  `telegram_update.message.from.id` (same lookup the trigger does) and
  self-gates against an already-running loop, so the success/failure paths
  and a concurrent text-triggered loop never double-start.

### 5. Store / fail functions (no `df.start`; `store` does the network fetch)

- `ow.store_inbound_attachment(slug, message_id, meta jsonb, file_url text,
  segment_duration float)`
  - Calls `ffmpeg.hls(file_url, segment_duration)` inside a `BEGIN … EXCEPTION`
    block. The network/decode call is folded in here (per chosen design), so
    `store` is **not** network-free and its happy path is not pgTAP-tested —
    it follows the existing convention that `ffmpeg.hls`'s networked path is
    not exercised in pgTAP (`60_tools.sql`).
  - On success: `payload = payload - 'attachment_pending' || {attachment: …}`
    where `attachment` is a small reference plus provenance (no bytes):
    `{kind, playlist_id, mime_type, filename, file_size, width, height}`.
  - On exception (network / decode / non-2xx, given `ffmpeg.hls` raises rather
    than returning a status): falls back to the fail path in-place — clears
    `attachment_pending` and appends the fail note to `content`. It **never
    RAISES**: a raised node would roll back the un-blocking UPDATE, and a
    stuck-pending message is worse than a lost file (the content note is the
    visibility).
- `ow.fail_inbound_attachment(slug, message_id, reason text)` clears
  `attachment_pending` and appends ` [attachment download failed: <reason>]`
  to `content`. Used only by the outer `df.if` else branch — the
  `getFile`-failed path.

Both run as `ow_agent_primary` inside the download instance; RLS already
allows own-agent `UPDATE` on `ow.messages`, and the RBAC grants
(`40-OpenWorld-rbac.sql`) already give the acting role `USAGE` on `ffmpeg`,
`EXECUTE` on `ffmpeg.hls`, plus `INSERT` on `hls_playlists`/`hls_segments`
and `USAGE, SELECT` on their id sequences. No new grants, roles, or
ownership changes are needed.

### 6. `ow.start_inbound_downloads(slug, poll_result jsonb)`

- For each entry in `poll_result.downloads`: resolve the message id via the
  `messages_telegram_update_agent_idx` unique key, then
  `df.start(ow.download_inbound_file_future(...), 'ow:download:<msg_id>')`.
- Label gate: skip when an instance with the same label is
  `pending`/`running`/`completed` — the inbox loop node replays after a
  crash, and `df.start` has no idempotency of its own. A `failed` instance
  may be re-started (retry).
- Runs as a node of the inbox loop (as `ow_agent_primary`, which holds
  `include_http`); starts commit when the node ends, same as
  `start_tool_calls`.

### 7. LLM context (21-OpenWorld-llm.sql)

For the model to "see" a photo or video its bytes must enter context **once**,
not every turn (context window). They no longer live on the message row —
they are reduced to **one thumbnail per segment** of the HLS playlist written
by §4. `_message_for_openai` gains `(p_multimodal boolean, p_inline boolean)`;
when both are true and the message carries a `photo` or `video` attachment,
content becomes the OpenAI multimodal shape with one `image_url` entry per
segment, each built by `ffmpeg.thumbnail` over that segment's bytes at
`seconds = 0.0` (the first frame):

```sql
SELECT jsonb_agg(
  jsonb_build_object(
    'type', 'image_url',
    'image_url', jsonb_build_object(
      'url', 'data:image/jpeg;base64,' ||
        encode(ffmpeg.thumbnail(s.data, 0.0, 'jpeg'), 'base64')
    )
  )
  ORDER BY s.segment_index
)
FROM ffmpeg.hls_segments s
WHERE s.playlist_id = attachment.playlist_id
```

```json
"content": [
  {"type": "text", "text": "[telegram 123] caption"},
  {"type": "image_url", "image_url": {"url": "data:image/jpeg;base64,…"}},
  {"type": "image_url", "image_url": {"url": "data:image/jpeg;base64,…"}}
]
```

- A photo ingests as a single segment → one `image_url` (a round-tripped,
  re-encoded frame of the original JPEG). A video ingests as N segments →
  N `image_url` entries, i.e. one frame every `segment_duration` seconds of
  the clip, giving the model a sampled visual summary of the whole video.
- `ffmpeg.thumbnail` at `seconds = 0.0` decodes the first frame of each
  segment; using `'jpeg'` keeps each entry small (a frame, not the raw
  segment). Per-segment thumbnails also keep the per-turn decode cost
  bounded by segment count, not by total media size.

`compose_llm_request` sets `p_inline` per row with the same turn-boundary
rule as before (`message.id > max(id of assistant messages with no
tool_calls)`) — attachments are thumbnailed for the **current turn only**
(including mid-turn tool-call iterations) and become text placeholders
again from the next turn on, so the per-turn `ffmpeg.thumbnail` cost is
paid once, not per iteration. `p_multimodal` comes from
`models.multimodal_support`; when it is false (or `p_inline` is false) the
attachment is emitted as its text placeholder only.

### 8. Tracing (31-OpenWorld-tracing.sql)

`parse_instance_label` gains a `download` arm: `ow:download:<msg_id>` →
kind `download`, message_id extracted. `trace_turn` then lists downloads
automatically (the photo/video message **is** the turn trigger).

## Failure & retry semantics

| Case | Handling |
|---|---|
| Same update re-polled (offset regression) | `messages_telegram_update_agent_idx` + `ON CONFLICT DO NOTHING` — no duplicate message |
| Inbox node replay after crash | label gate in `start_inbound_downloads` skips existing `ow:download:*` instances |
| `getFile` error / no `file_path` | `df.if` else branch → fail path → loop starts with the error noted |
| Download 4xx/5xx or decode failure | `ffmpeg.hls` raises inside `store` → `BEGIN…EXCEPTION` clears pending and writes the fail note (no RAISE, message never stuck pending) |
| Download instance fails unexpectedly | message stays pending until a later poll retry re-starts it; visible as failed instance |
| Engine down at `df.start` | inbox node raises → loop iteration retries with the same `$poll` replay |

## Limits

- Telegram bot download cap: 20 MB. Larger files fail at `getFile` → fail path.
- Bytes live in `ffmpeg.hls_playlists` / `hls_segments` (durable, dashboard-
  visible, same home as outbound media) — **not** on `ow.messages`. The message
  row carries only a `playlist_id` reference, so the ~33 % base64 / TOAST
  trade-off no longer touches the messages table at all; per-segment storage
  is pg_ffmpeg's existing cost model.
- Only the current turn's photos/videos are inlined into LLM context as
  per-segment thumbnails (see §7).
- LLM context grows by one `image_url` per HLS segment. For long videos,
  `segment_duration` (passed to `store`/`ffmpeg.hls`) is the cap on the
  frame count: e.g. 2.0 s segments on a 30 s clip → 15 frames. Choose a
  segment duration that bounds token cost; very long videos should use a
  larger duration. The thumbnail size (jpeg) is bounded regardless, since
  each frame is re-encoded, not the raw segment.

## Out of scope (follow-ups)

- voice/audio/document/sticker inbound (same machinery, different meta keys).
- Feeding documents to the model (needs a tool to read bytes, e.g. SQL tool
  over a bytea table, or text extraction).
- Adaptive segment duration / frame sampling (current §7 emits one frame
  per segment uniformly; smarter sampling — keyframes, scene changes, fewer
  frames for static content — is a follow-up).
- Typing indicator during the deferred window.
- Dashboard rendering of inbound attachments.

## Test plan (pgTAP, new `57_inbound_media.sql`)

1. `poll_messages` with a photo-only update → accepted, message inserted with
   `attachment_pending`, placeholder content, largest `file_id` chosen.
2. `poll_messages` with video + caption → caption content, meta preserved
   (kind `video`, dimensions/duration, default `video/mp4`).
3. `poll_messages` with sticker-only update → ignored (unchanged behaviour).
4. `poll_messages` with document-only update → ignored (now unsupported).
5. `store_inbound_attachment` happy path (real `ffmpeg.hls` fetch of a tiny
   fixture URL) → `attachment.playlist_id` written, pending cleared. Needs
   `ffmpeg.hls` + network, so lives in an integration suite (not `57_*`);
   skipped when ffmpeg/network unavailable, mirroring `60_tools.sql`.
6. `store_inbound_attachment` with an unreachable `file_url` (e.g.
   `http://127.0.0.1:1/x`) → `ffmpeg.hls` raises → `BEGIN…EXCEPTION` clears
   pending and appends the fail note; no RAISE escapes (pgTAP-testable).
7. `fail_inbound_attachment` → pending cleared, content appended.
8. `_message_for_openai` multimodal: a 3-segment video + inline → 3
   `image_url` data-URI entries (one `ffmpeg.thumbnail` per segment);
   not-inline / multimodal off → text-only placeholder.
9. `parse_instance_label('ow:download:42')` → kind/message_id arm (in
   90_tracing.sql).
