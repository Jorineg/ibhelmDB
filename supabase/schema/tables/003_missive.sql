-- =====================================
-- MISSIVE SCHEMA
-- =====================================

CREATE SCHEMA IF NOT EXISTS missive;

-- =====================================
-- BASE TABLES
-- =====================================

CREATE TABLE missive.contacts (
    id SERIAL PRIMARY KEY,
    name TEXT,
    email VARCHAR(500) NOT NULL UNIQUE,
    db_created_at TIMESTAMP DEFAULT NOW(),
    db_updated_at TIMESTAMP DEFAULT NOW()
);

CREATE TABLE missive.users (
    id UUID PRIMARY KEY,
    name TEXT,
    email VARCHAR(500),
    contact_id INTEGER REFERENCES missive.contacts(id) ON DELETE SET NULL,
    raw_data JSONB,
    db_created_at TIMESTAMP DEFAULT NOW(),
    db_updated_at TIMESTAMP DEFAULT NOW()
);

CREATE TABLE missive.teams (
    id UUID PRIMARY KEY,
    name TEXT NOT NULL,
    organization_id UUID,
    raw_data JSONB,
    db_created_at TIMESTAMP DEFAULT NOW(),
    db_updated_at TIMESTAMP DEFAULT NOW()
);

CREATE TABLE missive.shared_labels (
    id UUID PRIMARY KEY,
    name TEXT NOT NULL,
    raw_data JSONB,
    db_created_at TIMESTAMP DEFAULT NOW(),
    db_updated_at TIMESTAMP DEFAULT NOW()
);

CREATE TABLE missive.conversations (
    id UUID PRIMARY KEY,
    subject TEXT,
    latest_message_subject TEXT,
    organization_id UUID,
    color VARCHAR(50),
    attachments_count INTEGER DEFAULT 0,
    messages_count INTEGER DEFAULT 1,
    drafts_count INTEGER DEFAULT 0,
    send_later_messages_count INTEGER DEFAULT 0,
    tasks_count INTEGER DEFAULT 0,
    completed_tasks_count INTEGER DEFAULT 0,
    last_activity_at TIMESTAMP,
    web_url TEXT,
    app_url TEXT,
    raw_data JSONB,
    team_id UUID REFERENCES missive.teams(id) ON DELETE SET NULL,
    db_created_at TIMESTAMP DEFAULT NOW(),
    db_updated_at TIMESTAMP DEFAULT NOW()
);

CREATE TABLE missive.messages (
    id UUID PRIMARY KEY,
    conversation_id UUID REFERENCES missive.conversations(id) ON DELETE CASCADE,
    subject TEXT,
    preview TEXT,
    type VARCHAR(50),
    email_message_id TEXT,
    body TEXT,
    body_plain_text TEXT,
    from_contact_id INTEGER REFERENCES missive.contacts(id) ON DELETE SET NULL,
    delivered_at TIMESTAMP,
    created_at TIMESTAMP,
    updated_at TIMESTAMP,
    raw_data JSONB,
    db_created_at TIMESTAMP DEFAULT NOW(),
    db_updated_at TIMESTAMP DEFAULT NOW()
);

CREATE TABLE missive.attachments (
    id UUID PRIMARY KEY,
    message_id UUID REFERENCES missive.messages(id) ON DELETE CASCADE,
    filename VARCHAR(500),
    extension VARCHAR(50),
    url TEXT,
    media_type VARCHAR(100),
    sub_type VARCHAR(100),
    size INTEGER,
    width INTEGER,
    height INTEGER,
    raw_data JSONB,
    db_created_at TIMESTAMP DEFAULT NOW()
);

CREATE TABLE missive.message_recipients (
    id SERIAL PRIMARY KEY,
    message_id UUID REFERENCES missive.messages(id) ON DELETE CASCADE,
    recipient_type VARCHAR(10) NOT NULL,
    contact_id INTEGER REFERENCES missive.contacts(id) ON DELETE SET NULL
);

CREATE TABLE missive.conversation_authors (
    id SERIAL PRIMARY KEY,
    conversation_id UUID REFERENCES missive.conversations(id) ON DELETE CASCADE,
    contact_id INTEGER REFERENCES missive.contacts(id) ON DELETE SET NULL
);

CREATE TABLE missive.conversation_comments (
    id UUID PRIMARY KEY,
    conversation_id UUID NOT NULL REFERENCES missive.conversations(id) ON DELETE CASCADE,
    body TEXT,
    created_at TIMESTAMP,
    author_id UUID REFERENCES missive.users(id) ON DELETE SET NULL,
    raw_data JSONB,
    db_created_at TIMESTAMP DEFAULT NOW(),
    db_updated_at TIMESTAMP DEFAULT NOW()
);

CREATE TABLE missive.comment_attachments (
    id UUID PRIMARY KEY,
    comment_id UUID NOT NULL REFERENCES missive.conversation_comments(id) ON DELETE CASCADE,
    filename VARCHAR(500),
    extension VARCHAR(50),
    url TEXT,
    media_type VARCHAR(100),
    sub_type VARCHAR(100),
    size INTEGER,
    raw_data JSONB,
    db_created_at TIMESTAMP DEFAULT NOW()
);

CREATE TABLE missive.comment_mentions (
    id SERIAL PRIMARY KEY,
    comment_id UUID NOT NULL REFERENCES missive.conversation_comments(id) ON DELETE CASCADE,
    user_id UUID NOT NULL REFERENCES missive.users(id) ON DELETE CASCADE,
    mention_index INTEGER,
    mention_length INTEGER
);

CREATE TABLE missive.comment_tasks (
    id SERIAL PRIMARY KEY,
    comment_id UUID UNIQUE NOT NULL REFERENCES missive.conversation_comments(id) ON DELETE CASCADE,
    description TEXT,
    state VARCHAR(50),
    due_at TIMESTAMP,
    started_at TIMESTAMP,
    closed_at TIMESTAMP,
    team_id UUID REFERENCES missive.teams(id) ON DELETE SET NULL
);

CREATE TABLE missive.comment_task_assignees (
    comment_task_id INTEGER REFERENCES missive.comment_tasks(id) ON DELETE CASCADE,
    user_id UUID REFERENCES missive.users(id) ON DELETE CASCADE,
    PRIMARY KEY (comment_task_id, user_id)
);

-- =====================================
-- JUNCTION TABLES
-- =====================================

CREATE TABLE missive.conversation_users (
    conversation_id UUID REFERENCES missive.conversations(id) ON DELETE CASCADE,
    user_id UUID REFERENCES missive.users(id) ON DELETE CASCADE,
    unassigned BOOLEAN DEFAULT TRUE,
    closed BOOLEAN DEFAULT FALSE,
    archived BOOLEAN DEFAULT FALSE,
    trashed BOOLEAN DEFAULT FALSE,
    junked BOOLEAN DEFAULT FALSE,
    assigned BOOLEAN DEFAULT FALSE,
    flagged BOOLEAN DEFAULT FALSE,
    snoozed BOOLEAN DEFAULT FALSE,
    PRIMARY KEY (conversation_id, user_id)
);

CREATE TABLE missive.conversation_assignees (
    conversation_id UUID REFERENCES missive.conversations(id) ON DELETE CASCADE,
    user_id UUID REFERENCES missive.users(id) ON DELETE CASCADE,
    PRIMARY KEY (conversation_id, user_id)
);

CREATE TABLE missive.conversation_labels (
    label_id UUID REFERENCES missive.shared_labels(id) ON DELETE CASCADE,
    conversation_id UUID REFERENCES missive.conversations(id) ON DELETE CASCADE,
    PRIMARY KEY (conversation_id, label_id)
);

-- =====================================
-- INDEXES
-- =====================================

CREATE INDEX idx_m_contacts_email ON missive.contacts(email);
CREATE INDEX idx_m_contacts_name_lower ON missive.contacts(LOWER(name));
CREATE INDEX idx_m_users_email ON missive.users(email);
CREATE INDEX idx_m_users_contact_id ON missive.users(contact_id);
CREATE INDEX idx_m_teams_organization_id ON missive.teams(organization_id);
CREATE INDEX idx_m_shared_labels_name ON missive.shared_labels(name);
CREATE INDEX idx_m_conversations_team_id ON missive.conversations(team_id);
CREATE INDEX idx_m_conversations_last_activity_at ON missive.conversations(last_activity_at);
CREATE INDEX idx_m_messages_conversation_id ON missive.messages(conversation_id);
CREATE INDEX idx_m_messages_email_message_id ON missive.messages(email_message_id);
CREATE INDEX idx_m_messages_from_contact_id ON missive.messages(from_contact_id);
CREATE INDEX idx_m_messages_delivered_at ON missive.messages(delivered_at);
CREATE INDEX idx_m_messages_sort_date ON missive.messages(COALESCE(delivered_at, updated_at, created_at) DESC);
CREATE INDEX idx_m_attachments_message_id ON missive.attachments(message_id);
CREATE INDEX idx_m_message_recipients_message_id ON missive.message_recipients(message_id);
CREATE INDEX idx_m_message_recipients_contact_id ON missive.message_recipients(contact_id);
CREATE INDEX idx_m_message_recipients_type ON missive.message_recipients(recipient_type);
CREATE INDEX idx_m_conversation_authors_conversation_id ON missive.conversation_authors(conversation_id);
CREATE INDEX idx_m_conversation_authors_contact_id ON missive.conversation_authors(contact_id);
CREATE INDEX idx_m_conversation_users_conversation_id ON missive.conversation_users(conversation_id);
CREATE INDEX idx_m_conversation_users_user_id ON missive.conversation_users(user_id);
CREATE INDEX idx_m_conversation_assignees_conversation_id ON missive.conversation_assignees(conversation_id);
CREATE INDEX idx_m_conversation_assignees_user_id ON missive.conversation_assignees(user_id);
CREATE INDEX idx_m_conversation_labels_conversation_id ON missive.conversation_labels(conversation_id);
CREATE INDEX idx_m_conversation_labels_label_id ON missive.conversation_labels(label_id);
CREATE INDEX idx_m_conversation_comments_conversation_id ON missive.conversation_comments(conversation_id);
CREATE INDEX idx_m_conversation_comments_author_id ON missive.conversation_comments(author_id);
CREATE INDEX idx_m_conversation_comments_created_at ON missive.conversation_comments(created_at);
CREATE INDEX idx_m_comment_attachments_comment_id ON missive.comment_attachments(comment_id);
CREATE INDEX idx_m_comment_mentions_comment_id ON missive.comment_mentions(comment_id);
CREATE INDEX idx_m_comment_mentions_user_id ON missive.comment_mentions(user_id);
CREATE INDEX idx_m_comment_tasks_comment_id ON missive.comment_tasks(comment_id);
CREATE INDEX idx_m_comment_tasks_team_id ON missive.comment_tasks(team_id);
CREATE INDEX idx_m_comment_tasks_state ON missive.comment_tasks(state);
CREATE INDEX idx_m_comment_task_assignees_comment_task_id ON missive.comment_task_assignees(comment_task_id);
CREATE INDEX idx_m_comment_task_assignees_user_id ON missive.comment_task_assignees(user_id);

-- Performance indexes
CREATE INDEX idx_m_messages_conversation_delivered ON missive.messages(conversation_id, delivered_at DESC);

-- =====================================
-- COMMENTS
-- =====================================

COMMENT ON SCHEMA missive IS 'External data from Missive email collaboration system';
COMMENT ON TABLE missive.contacts IS 'Email correspondents (external contacts)';
COMMENT ON TABLE missive.message_recipients IS 'Normalized to/cc/bcc fields from messages';
COMMENT ON COLUMN missive.messages.body_plain_text IS 'Plain text extracted from HTML body for searching and display';

