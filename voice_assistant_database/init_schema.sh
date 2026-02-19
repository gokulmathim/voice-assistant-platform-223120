#!/bin/bash
set -euo pipefail

# Initializes the Voice Assistant database schema (idempotent).
# This script is intended to be run automatically by startup.sh once PostgreSQL is up.

DB_CONN_CMD_FILE="db_connection.txt"

if [ ! -f "${DB_CONN_CMD_FILE}" ]; then
  echo "ERROR: ${DB_CONN_CMD_FILE} not found. startup.sh should create it."
  exit 1
fi

PSQL_CMD="$(cat "${DB_CONN_CMD_FILE}")"

echo "Running schema initialization..."

# Each statement is executed individually to keep the script robust and easier to debug.

# 1) Extensions
${PSQL_CMD} -v ON_ERROR_STOP=1 -c 'CREATE EXTENSION IF NOT EXISTS pgcrypto;'
${PSQL_CMD} -v ON_ERROR_STOP=1 -c 'CREATE EXTENSION IF NOT EXISTS citext;'

# 2) Helper trigger function for updated_at
${PSQL_CMD} -v ON_ERROR_STOP=1 -c '
CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;
'

# 3) Users table (supports authenticated users; backend can also use anonymous sessions)
${PSQL_CMD} -v ON_ERROR_STOP=1 -c '
CREATE TABLE IF NOT EXISTS users (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  email CITEXT UNIQUE,
  display_name TEXT,
  is_anonymous BOOLEAN NOT NULL DEFAULT FALSE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  last_seen_at TIMESTAMPTZ
);
'

${PSQL_CMD} -v ON_ERROR_STOP=1 -c '
DROP TRIGGER IF EXISTS trg_users_set_updated_at ON users;
CREATE TRIGGER trg_users_set_updated_at
BEFORE UPDATE ON users
FOR EACH ROW EXECUTE FUNCTION set_updated_at();
'

# 4) Anonymous sessions table (for unauthenticated usage)
${PSQL_CMD} -v ON_ERROR_STOP=1 -c '
CREATE TABLE IF NOT EXISTS anonymous_sessions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  session_token TEXT UNIQUE NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  last_seen_at TIMESTAMPTZ,
  ip_hash TEXT,
  user_agent_hash TEXT
);
'

${PSQL_CMD} -v ON_ERROR_STOP=1 -c '
CREATE INDEX IF NOT EXISTS idx_anonymous_sessions_last_seen_at
ON anonymous_sessions (last_seen_at DESC);
'

# 5) User settings (language/voice/wake word + misc settings)
${PSQL_CMD} -v ON_ERROR_STOP=1 -c '
CREATE TABLE IF NOT EXISTS user_settings (
  user_id UUID PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
  language_code TEXT NOT NULL DEFAULT ''en-US'',
  voice_id TEXT,
  wake_word_enabled BOOLEAN NOT NULL DEFAULT FALSE,
  wake_word TEXT,
  tts_enabled BOOLEAN NOT NULL DEFAULT TRUE,
  stt_provider TEXT,
  tts_provider TEXT,
  llm_provider TEXT,
  settings_json JSONB NOT NULL DEFAULT ''{}''::jsonb,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
'

${PSQL_CMD} -v ON_ERROR_STOP=1 -c '
DROP TRIGGER IF EXISTS trg_user_settings_set_updated_at ON user_settings;
CREATE TRIGGER trg_user_settings_set_updated_at
BEFORE UPDATE ON user_settings
FOR EACH ROW EXECUTE FUNCTION set_updated_at();
'

# 6) Conversations
# Supports either user_id or anonymous_session_id ownership. Exactly one should be set.
${PSQL_CMD} -v ON_ERROR_STOP=1 -c '
CREATE TABLE IF NOT EXISTS conversations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID REFERENCES users(id) ON DELETE SET NULL,
  anonymous_session_id UUID REFERENCES anonymous_sessions(id) ON DELETE SET NULL,
  title TEXT,
  status TEXT NOT NULL DEFAULT ''active'',
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  last_message_at TIMESTAMPTZ,

  CONSTRAINT conversations_owner_chk
    CHECK (
      (user_id IS NOT NULL AND anonymous_session_id IS NULL)
      OR (user_id IS NULL AND anonymous_session_id IS NOT NULL)
    )
);
'

${PSQL_CMD} -v ON_ERROR_STOP=1 -c '
DROP TRIGGER IF EXISTS trg_conversations_set_updated_at ON conversations;
CREATE TRIGGER trg_conversations_set_updated_at
BEFORE UPDATE ON conversations
FOR EACH ROW EXECUTE FUNCTION set_updated_at();
'

# Efficient history listing
${PSQL_CMD} -v ON_ERROR_STOP=1 -c '
CREATE INDEX IF NOT EXISTS idx_conversations_user_last_message_at
ON conversations (user_id, last_message_at DESC NULLS LAST, created_at DESC);
'

${PSQL_CMD} -v ON_ERROR_STOP=1 -c '
CREATE INDEX IF NOT EXISTS idx_conversations_anon_last_message_at
ON conversations (anonymous_session_id, last_message_at DESC NULLS LAST, created_at DESC);
'

# 7) Messages
# message ordering: use (conversation_id, created_at, id) index for stable pagination and ordering.
${PSQL_CMD} -v ON_ERROR_STOP=1 -c '
CREATE TABLE IF NOT EXISTS messages (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  conversation_id UUID NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
  role TEXT NOT NULL, -- user | assistant | system | tool
  content TEXT,
  content_json JSONB, -- optional richer format (tool calls, etc.)
  audio_url TEXT,
  tokens_in INTEGER,
  tokens_out INTEGER,
  model TEXT,
  provider TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  CONSTRAINT messages_role_chk CHECK (role IN (''user'',''assistant'',''system'',''tool''))
);
'

${PSQL_CMD} -v ON_ERROR_STOP=1 -c '
CREATE INDEX IF NOT EXISTS idx_messages_conversation_created_at
ON messages (conversation_id, created_at ASC, id ASC);
'

${PSQL_CMD} -v ON_ERROR_STOP=1 -c '
CREATE INDEX IF NOT EXISTS idx_messages_conversation_role_created_at
ON messages (conversation_id, role, created_at ASC);
'

# 8) Minimal audit log (backend can write here for key events)
${PSQL_CMD} -v ON_ERROR_STOP=1 -c '
CREATE TABLE IF NOT EXISTS audit_events (
  id BIGSERIAL PRIMARY KEY,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  user_id UUID REFERENCES users(id) ON DELETE SET NULL,
  anonymous_session_id UUID REFERENCES anonymous_sessions(id) ON DELETE SET NULL,
  conversation_id UUID REFERENCES conversations(id) ON DELETE SET NULL,
  event_type TEXT NOT NULL,
  event_data JSONB NOT NULL DEFAULT ''{}''::jsonb,
  ip_hash TEXT,
  user_agent_hash TEXT
);
'

${PSQL_CMD} -v ON_ERROR_STOP=1 -c '
CREATE INDEX IF NOT EXISTS idx_audit_events_created_at
ON audit_events (created_at DESC);
'

${PSQL_CMD} -v ON_ERROR_STOP=1 -c '
CREATE INDEX IF NOT EXISTS idx_audit_events_user_created_at
ON audit_events (user_id, created_at DESC);
'

${PSQL_CMD} -v ON_ERROR_STOP=1 -c '
CREATE INDEX IF NOT EXISTS idx_audit_events_session_created_at
ON audit_events (anonymous_session_id, created_at DESC);
'

# 9) Minimal rate-limit buckets (generic; supports per-user/per-session/per-ip buckets)
${PSQL_CMD} -v ON_ERROR_STOP=1 -c '
CREATE TABLE IF NOT EXISTS rate_limit_buckets (
  id BIGSERIAL PRIMARY KEY,
  bucket_key TEXT NOT NULL,
  window_start TIMESTAMPTZ NOT NULL,
  window_seconds INTEGER NOT NULL,
  request_count INTEGER NOT NULL DEFAULT 0,
  last_request_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  CONSTRAINT rate_limit_buckets_uniq UNIQUE (bucket_key, window_start, window_seconds)
);
'

${PSQL_CMD} -v ON_ERROR_STOP=1 -c '
CREATE INDEX IF NOT EXISTS idx_rate_limit_buckets_key_window
ON rate_limit_buckets (bucket_key, window_start DESC);
'

# 10) Trigger to keep conversations.last_message_at in sync
${PSQL_CMD} -v ON_ERROR_STOP=1 -c '
CREATE OR REPLACE FUNCTION update_conversation_last_message_at()
RETURNS TRIGGER AS $$
BEGIN
  UPDATE conversations
  SET last_message_at = GREATEST(COALESCE(last_message_at, NEW.created_at), NEW.created_at)
  WHERE id = NEW.conversation_id;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;
'

${PSQL_CMD} -v ON_ERROR_STOP=1 -c '
DROP TRIGGER IF EXISTS trg_messages_update_conversation_last_message_at ON messages;
CREATE TRIGGER trg_messages_update_conversation_last_message_at
AFTER INSERT ON messages
FOR EACH ROW EXECUTE FUNCTION update_conversation_last_message_at();
'

# 11) Minimal seed: create a "demo anonymous session" (optional; safe to keep empty otherwise)
${PSQL_CMD} -v ON_ERROR_STOP=1 -c "
INSERT INTO anonymous_sessions (session_token)
VALUES ('demo-session-token')
ON CONFLICT (session_token) DO NOTHING;
"

echo "Schema initialization complete."
