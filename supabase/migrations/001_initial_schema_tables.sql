-- ========================================
-- TEAMWORK TABLES
-- ========================================

-- Teamwork Companies
CREATE TABLE IF NOT EXISTS tw_companies (
    id INTEGER PRIMARY KEY,
    name TEXT,
    address_one TEXT,
    address_two TEXT,
    city TEXT,
    state TEXT,
    zip TEXT,
    country_code VARCHAR(10),
    phone VARCHAR(100),
    fax VARCHAR(100),
    email_one VARCHAR(500),
    email_two VARCHAR(500),
    email_three VARCHAR(500),
    website TEXT,
    industry_id INTEGER,
    logo_url TEXT,
    can_see_private BOOLEAN,
    is_owner BOOLEAN,
    status VARCHAR(50),
    private_notes TEXT,
    private_notes_text TEXT,
    profile_text TEXT,
    created_at TIMESTAMP,
    updated_at TIMESTAMP,
    raw_data JSONB,
    db_created_at TIMESTAMP DEFAULT NOW(),
    db_updated_at TIMESTAMP DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_tw_companies_name ON tw_companies(name);

-- Teamwork Users
CREATE TABLE IF NOT EXISTS tw_users (
    id INTEGER PRIMARY KEY,
    first_name TEXT,
    last_name TEXT,
    email VARCHAR(500),
    avatar_url TEXT,
    title TEXT,
    company_id INTEGER REFERENCES tw_companies(id) ON DELETE SET NULL,
    company_role_id INTEGER,
    is_admin BOOLEAN,
    is_client_user BOOLEAN,
    is_placeholder_resource BOOLEAN,
    is_service_account BOOLEAN,
    deleted BOOLEAN DEFAULT FALSE,
    can_add_projects BOOLEAN,
    can_access_portfolio BOOLEAN,
    can_manage_portfolio BOOLEAN,
    timezone VARCHAR(100),
    length_of_day DECIMAL,
    user_cost DECIMAL,
    user_rate DECIMAL,
    last_login TIMESTAMP,
    created_at TIMESTAMP,
    updated_at TIMESTAMP,
    raw_data JSONB,
    db_created_at TIMESTAMP DEFAULT NOW(),
    db_updated_at TIMESTAMP DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_tw_users_email ON tw_users(email);
CREATE INDEX IF NOT EXISTS idx_tw_users_company_id ON tw_users(company_id);
CREATE INDEX IF NOT EXISTS idx_tw_users_deleted ON tw_users(deleted);

-- Teamwork Teams
CREATE TABLE IF NOT EXISTS tw_teams (
    id INTEGER PRIMARY KEY,
    name TEXT NOT NULL,
    handle TEXT,
    team_logo TEXT,
    team_logo_color VARCHAR(50),
    team_logo_icon TEXT,
    created_at TIMESTAMP,
    updated_at TIMESTAMP,
    raw_data JSONB,
    db_created_at TIMESTAMP DEFAULT NOW(),
    db_updated_at TIMESTAMP DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_tw_teams_name ON tw_teams(name);

-- Teamwork Tags
CREATE TABLE IF NOT EXISTS tw_tags (
    id INTEGER PRIMARY KEY,
    name TEXT NOT NULL,
    color VARCHAR(50),
    project_id INTEGER,
    count INTEGER DEFAULT 0,
    raw_data JSONB,
    db_created_at TIMESTAMP DEFAULT NOW(),
    db_updated_at TIMESTAMP DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_tw_tags_name ON tw_tags(name);
CREATE INDEX IF NOT EXISTS idx_tw_tags_project_id ON tw_tags(project_id);

-- Teamwork Projects
CREATE TABLE IF NOT EXISTS tw_projects (
    id INTEGER PRIMARY KEY,
    name TEXT NOT NULL,
    description TEXT,
    company_id INTEGER REFERENCES tw_companies(id) ON DELETE SET NULL,
    owner_id INTEGER REFERENCES tw_users(id) ON DELETE SET NULL,
    category_id INTEGER,
    status VARCHAR(50),
    sub_status VARCHAR(50),
    start_date DATE,
    end_date DATE,
    start_at TIMESTAMP,
    end_at TIMESTAMP,
    completed_at TIMESTAMP,
    completed_by INTEGER REFERENCES tw_users(id) ON DELETE SET NULL,
    created_by INTEGER REFERENCES tw_users(id) ON DELETE SET NULL,
    updated_by INTEGER REFERENCES tw_users(id) ON DELETE SET NULL,
    is_starred BOOLEAN,
    is_billable BOOLEAN,
    is_sample_project BOOLEAN,
    is_onboarding_project BOOLEAN,
    is_project_admin BOOLEAN,
    logo TEXT,
    logo_color VARCHAR(50),
    logo_icon TEXT,
    announcement TEXT,
    show_announcement BOOLEAN,
    default_privacy VARCHAR(50),
    privacy_enabled BOOLEAN,
    harvest_timers_enabled BOOLEAN,
    notify_everyone BOOLEAN,
    skip_weekends BOOLEAN,
    created_at TIMESTAMP,
    updated_at TIMESTAMP,
    last_worked_on TIMESTAMP,
    raw_data JSONB,
    db_created_at TIMESTAMP DEFAULT NOW(),
    db_updated_at TIMESTAMP DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_tw_projects_name ON tw_projects(name);
CREATE INDEX IF NOT EXISTS idx_tw_projects_company_id ON tw_projects(company_id);
CREATE INDEX IF NOT EXISTS idx_tw_projects_status ON tw_projects(status);

-- Teamwork Tasklists
CREATE TABLE IF NOT EXISTS tw_tasklists (
    id INTEGER PRIMARY KEY,
    name TEXT NOT NULL,
    description TEXT,
    project_id INTEGER REFERENCES tw_projects(id) ON DELETE CASCADE,
    milestone_id INTEGER,
    status VARCHAR(50),
    display_order INTEGER,
    is_private BOOLEAN,
    is_pinned BOOLEAN,
    is_billable BOOLEAN,
    icon TEXT,
    lockdown_id INTEGER,
    calculated_start_date DATE,
    calculated_due_date DATE,
    created_at TIMESTAMP,
    updated_at TIMESTAMP,
    raw_data JSONB,
    db_created_at TIMESTAMP DEFAULT NOW(),
    db_updated_at TIMESTAMP DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_tw_tasklists_name ON tw_tasklists(name);
CREATE INDEX IF NOT EXISTS idx_tw_tasklists_project_id ON tw_tasklists(project_id);

-- Tasks table (with foreign keys)
CREATE TABLE IF NOT EXISTS tasks (
    id SERIAL PRIMARY KEY,
    task_id VARCHAR(255) UNIQUE NOT NULL,
    name TEXT,
    description TEXT,
    status VARCHAR(100),
    priority VARCHAR(50),
    progress INTEGER,
    project_id INTEGER REFERENCES tw_projects(id) ON DELETE SET NULL,
    tasklist_id INTEGER REFERENCES tw_tasklists(id) ON DELETE SET NULL,
    parent_task VARCHAR(255) REFERENCES tasks(task_id) ON DELETE SET NULL
        DEFERRABLE INITIALLY DEFERRED,
    start_date TIMESTAMP,
    due_date TIMESTAMP,
    estimate_minutes INTEGER,
    accumulated_estimated_minutes INTEGER,
    created_at TIMESTAMP,
    created_by_id INTEGER REFERENCES tw_users(id) ON DELETE SET NULL,
    updated_at TIMESTAMP,
    updated_by_id INTEGER REFERENCES tw_users(id) ON DELETE SET NULL,
    deleted_at TIMESTAMP,
    source_links JSONB,
    raw_data JSONB,
    db_created_at TIMESTAMP DEFAULT NOW(),
    db_updated_at TIMESTAMP DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_tasks_task_id ON tasks(task_id);
CREATE INDEX IF NOT EXISTS idx_tasks_project_id ON tasks(project_id);
CREATE INDEX IF NOT EXISTS idx_tasks_tasklist_id ON tasks(tasklist_id);
CREATE INDEX IF NOT EXISTS idx_tasks_parent_task ON tasks(parent_task);
CREATE INDEX IF NOT EXISTS idx_tasks_deleted_at ON tasks(deleted_at);
CREATE INDEX IF NOT EXISTS idx_tasks_updated_at ON tasks(updated_at);

-- Task-Tag junction table (many-to-many)
CREATE TABLE IF NOT EXISTS task_tags (
    task_id VARCHAR(255) REFERENCES tasks(task_id) ON DELETE CASCADE,
    tag_id INTEGER REFERENCES tw_tags(id) ON DELETE CASCADE,
    PRIMARY KEY (task_id, tag_id)
);
CREATE INDEX IF NOT EXISTS idx_task_tags_task_id ON task_tags(task_id);
CREATE INDEX IF NOT EXISTS idx_task_tags_tag_id ON task_tags(tag_id);

-- Task-Assignee junction table (many-to-many)
CREATE TABLE IF NOT EXISTS task_assignees (
    task_id VARCHAR(255) REFERENCES tasks(task_id) ON DELETE CASCADE,
    user_id INTEGER REFERENCES tw_users(id) ON DELETE CASCADE,
    PRIMARY KEY (task_id, user_id)
);
CREATE INDEX IF NOT EXISTS idx_task_assignees_task_id ON task_assignees(task_id);
CREATE INDEX IF NOT EXISTS idx_task_assignees_user_id ON task_assignees(user_id);

-- User-Team junction table (many-to-many)
CREATE TABLE IF NOT EXISTS tw_user_teams (
    user_id INTEGER REFERENCES tw_users(id) ON DELETE CASCADE,
    team_id INTEGER REFERENCES tw_teams(id) ON DELETE CASCADE,
    PRIMARY KEY (user_id, team_id)
);
CREATE INDEX IF NOT EXISTS idx_tw_user_teams_user_id ON tw_user_teams(user_id);
CREATE INDEX IF NOT EXISTS idx_tw_user_teams_team_id ON tw_user_teams(team_id);

-- ========================================
-- MISSIVE TABLES
-- ========================================

-- Missive Contacts (email correspondents - created before m_users)
CREATE TABLE IF NOT EXISTS m_contacts (
    id SERIAL PRIMARY KEY,
    name TEXT,
    email VARCHAR(500) NOT NULL UNIQUE,
    db_created_at TIMESTAMP DEFAULT NOW(),
    db_updated_at TIMESTAMP DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_m_contacts_email ON m_contacts(email);

-- Missive Users
CREATE TABLE IF NOT EXISTS m_users (
    id UUID PRIMARY KEY,
    name TEXT,
    email VARCHAR(500),
    contact_id INTEGER REFERENCES m_contacts(id) ON DELETE SET NULL,
    raw_data JSONB,
    db_created_at TIMESTAMP DEFAULT NOW(),
    db_updated_at TIMESTAMP DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_m_users_email ON m_users(email);
CREATE INDEX IF NOT EXISTS idx_m_users_contact_id ON m_users(contact_id);

-- Missive Teams
CREATE TABLE IF NOT EXISTS m_teams (
    id UUID PRIMARY KEY,
    name TEXT NOT NULL,
    organization_id UUID,
    raw_data JSONB,
    db_created_at TIMESTAMP DEFAULT NOW(),
    db_updated_at TIMESTAMP DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_m_teams_organization_id ON m_teams(organization_id);

-- Missive Shared Labels
CREATE TABLE IF NOT EXISTS m_shared_labels (
    id UUID PRIMARY KEY,
    name TEXT NOT NULL,
    raw_data JSONB,
    db_created_at TIMESTAMP DEFAULT NOW(),
    db_updated_at TIMESTAMP DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_m_shared_labels_name ON m_shared_labels(name);

-- Missive Conversations
CREATE TABLE IF NOT EXISTS m_conversations (
    id UUID PRIMARY KEY,
    subject TEXT,
    latest_message_subject TEXT,
    team_id UUID REFERENCES m_teams(id) ON DELETE SET NULL,
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
    db_created_at TIMESTAMP DEFAULT NOW(),
    db_updated_at TIMESTAMP DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_m_conversations_team_id ON m_conversations(team_id);
CREATE INDEX IF NOT EXISTS idx_m_conversations_last_activity_at ON m_conversations(last_activity_at);

-- Conversation-User junction table (many-to-many) for users in a conversation
CREATE TABLE IF NOT EXISTS m_conversation_users (
    conversation_id UUID REFERENCES m_conversations(id) ON DELETE CASCADE,
    user_id UUID REFERENCES m_users(id) ON DELETE CASCADE,
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
CREATE INDEX IF NOT EXISTS idx_m_conversation_users_conversation_id ON m_conversation_users(conversation_id);
CREATE INDEX IF NOT EXISTS idx_m_conversation_users_user_id ON m_conversation_users(user_id);

-- Conversation-User junction table for assignees specifically
CREATE TABLE IF NOT EXISTS m_conversation_assignees (
    conversation_id UUID REFERENCES m_conversations(id) ON DELETE CASCADE,
    user_id UUID REFERENCES m_users(id) ON DELETE CASCADE,
    PRIMARY KEY (conversation_id, user_id)
);
CREATE INDEX IF NOT EXISTS idx_m_conversation_assignees_conversation_id ON m_conversation_assignees(conversation_id);
CREATE INDEX IF NOT EXISTS idx_m_conversation_assignees_user_id ON m_conversation_assignees(user_id);

-- Conversation-SharedLabel junction table (many-to-many)
CREATE TABLE IF NOT EXISTS m_conversation_labels (
    conversation_id UUID REFERENCES m_conversations(id) ON DELETE CASCADE,
    label_id UUID REFERENCES m_shared_labels(id) ON DELETE CASCADE,
    PRIMARY KEY (conversation_id, label_id)
);
CREATE INDEX IF NOT EXISTS idx_m_conversation_labels_conversation_id ON m_conversation_labels(conversation_id);
CREATE INDEX IF NOT EXISTS idx_m_conversation_labels_label_id ON m_conversation_labels(label_id);

-- Missive Messages (emails)
CREATE TABLE IF NOT EXISTS m_messages (
    id UUID PRIMARY KEY,
    conversation_id UUID REFERENCES m_conversations(id) ON DELETE CASCADE,
    subject TEXT,
    preview TEXT,
    type VARCHAR(50),
    email_message_id TEXT,
    body TEXT,
    from_contact_id INTEGER REFERENCES m_contacts(id) ON DELETE SET NULL,
    delivered_at TIMESTAMP,
    created_at TIMESTAMP,
    updated_at TIMESTAMP,
    raw_data JSONB,
    db_created_at TIMESTAMP DEFAULT NOW(),
    db_updated_at TIMESTAMP DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_m_messages_conversation_id ON m_messages(conversation_id);
CREATE INDEX IF NOT EXISTS idx_m_messages_email_message_id ON m_messages(email_message_id);
CREATE INDEX IF NOT EXISTS idx_m_messages_from_contact_id ON m_messages(from_contact_id);
CREATE INDEX IF NOT EXISTS idx_m_messages_delivered_at ON m_messages(delivered_at);

-- Message recipients (to/cc/bcc fields normalized)
CREATE TABLE IF NOT EXISTS m_message_recipients (
    id SERIAL PRIMARY KEY,
    message_id UUID REFERENCES m_messages(id) ON DELETE CASCADE,
    recipient_type VARCHAR(10) NOT NULL,
    contact_id INTEGER REFERENCES m_contacts(id) ON DELETE SET NULL
);
CREATE INDEX IF NOT EXISTS idx_m_message_recipients_message_id ON m_message_recipients(message_id);
CREATE INDEX IF NOT EXISTS idx_m_message_recipients_contact_id ON m_message_recipients(contact_id);
CREATE INDEX IF NOT EXISTS idx_m_message_recipients_type ON m_message_recipients(recipient_type);

-- Missive Attachments
CREATE TABLE IF NOT EXISTS m_attachments (
    id UUID PRIMARY KEY,
    message_id UUID REFERENCES m_messages(id) ON DELETE CASCADE,
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
CREATE INDEX IF NOT EXISTS idx_m_attachments_message_id ON m_attachments(message_id);

-- Conversation authors (can be multiple for a conversation)
CREATE TABLE IF NOT EXISTS m_conversation_authors (
    id SERIAL PRIMARY KEY,
    conversation_id UUID REFERENCES m_conversations(id) ON DELETE CASCADE,
    contact_id INTEGER REFERENCES m_contacts(id) ON DELETE SET NULL
);
CREATE INDEX IF NOT EXISTS idx_m_conversation_authors_conversation_id ON m_conversation_authors(conversation_id);
CREATE INDEX IF NOT EXISTS idx_m_conversation_authors_contact_id ON m_conversation_authors(contact_id);

-- ========================================
-- SYSTEM TABLES
-- ========================================

-- Checkpoints table
CREATE TABLE IF NOT EXISTS checkpoints (
    source VARCHAR(50) PRIMARY KEY,
    last_event_time TIMESTAMP NOT NULL,
    last_cursor TEXT,
    updated_at TIMESTAMP DEFAULT NOW()
);

