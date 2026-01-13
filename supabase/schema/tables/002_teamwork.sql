-- =====================================
-- TEAMWORK SCHEMA
-- =====================================

CREATE SCHEMA IF NOT EXISTS teamwork;

-- =====================================
-- BASE TABLES
-- =====================================

CREATE TABLE teamwork.companies (
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

CREATE TABLE teamwork.users (
    id INTEGER PRIMARY KEY,
    first_name TEXT,
    last_name TEXT,
    email VARCHAR(500),
    avatar_url TEXT,
    title TEXT,
    company_id INTEGER REFERENCES teamwork.companies(id) ON DELETE SET NULL,
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

CREATE TABLE teamwork.teams (
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

CREATE TABLE teamwork.tags (
    id INTEGER PRIMARY KEY,
    name TEXT NOT NULL,
    color VARCHAR(50),
    project_id INTEGER,
    count INTEGER DEFAULT 0,
    raw_data JSONB,
    db_created_at TIMESTAMP DEFAULT NOW(),
    db_updated_at TIMESTAMP DEFAULT NOW()
);

CREATE TABLE teamwork.projects (
    id INTEGER PRIMARY KEY,
    name TEXT NOT NULL,
    description TEXT,
    company_id INTEGER REFERENCES teamwork.companies(id) ON DELETE SET NULL,
    category_id INTEGER,
    status VARCHAR(50),
    sub_status VARCHAR(50),
    start_date DATE,
    end_date DATE,
    start_at TIMESTAMP,
    end_at TIMESTAMP,
    completed_at TIMESTAMP,
    owner_id INTEGER REFERENCES teamwork.users(id) ON DELETE SET NULL,
    completed_by INTEGER REFERENCES teamwork.users(id) ON DELETE SET NULL,
    created_by INTEGER REFERENCES teamwork.users(id) ON DELETE SET NULL,
    updated_by INTEGER REFERENCES teamwork.users(id) ON DELETE SET NULL,
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

CREATE TABLE teamwork.tasklists (
    id INTEGER PRIMARY KEY,
    name TEXT NOT NULL,
    description TEXT,
    project_id INTEGER REFERENCES teamwork.projects(id) ON DELETE CASCADE,
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

CREATE TABLE teamwork.tasks (
    id INTEGER PRIMARY KEY,
    project_id INTEGER REFERENCES teamwork.projects(id) ON DELETE SET NULL,
    tasklist_id INTEGER REFERENCES teamwork.tasklists(id) ON DELETE SET NULL,
    name TEXT,
    description TEXT,
    status VARCHAR(100),
    priority VARCHAR(50),
    progress INTEGER,
    parent_task INTEGER REFERENCES teamwork.tasks(id) ON DELETE SET NULL DEFERRABLE INITIALLY DEFERRED,
    start_date TIMESTAMP,
    due_date TIMESTAMP,
    estimate_minutes INTEGER,
    accumulated_estimated_minutes INTEGER,
    created_at TIMESTAMP,
    created_by_id INTEGER REFERENCES teamwork.users(id) ON DELETE SET NULL,
    updated_at TIMESTAMP,
    updated_by_id INTEGER REFERENCES teamwork.users(id) ON DELETE SET NULL,
    deleted_at TIMESTAMP,
    source_links JSONB,
    raw_data JSONB,
    db_created_at TIMESTAMP DEFAULT NOW(),
    db_updated_at TIMESTAMP DEFAULT NOW()
);

-- =====================================
-- JUNCTION TABLES
-- =====================================

CREATE TABLE teamwork.task_tags (
    task_id INTEGER REFERENCES teamwork.tasks(id) ON DELETE CASCADE,
    tag_id INTEGER REFERENCES teamwork.tags(id) ON DELETE CASCADE,
    PRIMARY KEY (task_id, tag_id)
);

CREATE TABLE teamwork.task_assignees (
    task_id INTEGER REFERENCES teamwork.tasks(id) ON DELETE CASCADE,
    user_id INTEGER REFERENCES teamwork.users(id) ON DELETE CASCADE,
    PRIMARY KEY (task_id, user_id)
);

CREATE TABLE teamwork.user_teams (
    user_id INTEGER REFERENCES teamwork.users(id) ON DELETE CASCADE,
    team_id INTEGER REFERENCES teamwork.teams(id) ON DELETE CASCADE,
    PRIMARY KEY (user_id, team_id)
);

-- =====================================
-- TIME TRACKING
-- =====================================

CREATE TABLE teamwork.timelogs (
    id INTEGER PRIMARY KEY,
    task_id INTEGER REFERENCES teamwork.tasks(id) ON DELETE SET NULL,
    project_id INTEGER REFERENCES teamwork.projects(id) ON DELETE SET NULL,
    user_id INTEGER REFERENCES teamwork.users(id) ON DELETE SET NULL,
    logged_by_user_id INTEGER REFERENCES teamwork.users(id) ON DELETE SET NULL,
    minutes INTEGER NOT NULL,
    description TEXT,
    time_logged TIMESTAMP,
    has_start_time BOOLEAN,
    is_billable BOOLEAN,
    deleted BOOLEAN DEFAULT FALSE,
    deleted_at TIMESTAMP,
    deleted_by_user_id INTEGER REFERENCES teamwork.users(id) ON DELETE SET NULL,
    edited_at TIMESTAMP,
    edited_by_user_id INTEGER REFERENCES teamwork.users(id) ON DELETE SET NULL,
    invoice_id INTEGER,
    created_at TIMESTAMP,
    raw_data JSONB,
    db_created_at TIMESTAMP DEFAULT NOW(),
    db_updated_at TIMESTAMP DEFAULT NOW()
);

-- =====================================
-- INDEXES
-- =====================================

CREATE INDEX idx_tw_companies_name ON teamwork.companies(name);
CREATE INDEX idx_tw_users_email ON teamwork.users(email);
CREATE INDEX idx_tw_users_company_id ON teamwork.users(company_id);
CREATE INDEX idx_tw_users_deleted ON teamwork.users(deleted);
CREATE INDEX idx_tw_teams_name ON teamwork.teams(name);
CREATE INDEX idx_tw_tags_name ON teamwork.tags(name);
CREATE INDEX idx_tw_tags_project_id ON teamwork.tags(project_id);
CREATE INDEX idx_tw_projects_name ON teamwork.projects(name);
CREATE INDEX idx_tw_projects_company_id ON teamwork.projects(company_id);
CREATE INDEX idx_tw_projects_status ON teamwork.projects(status);
CREATE INDEX idx_tw_tasklists_name ON teamwork.tasklists(name);
CREATE INDEX idx_tw_tasklists_project_id ON teamwork.tasklists(project_id);
CREATE INDEX idx_tw_tasks_id ON teamwork.tasks(id);
CREATE INDEX idx_tw_tasks_project_id ON teamwork.tasks(project_id);
CREATE INDEX idx_tw_tasks_tasklist_id ON teamwork.tasks(tasklist_id);
CREATE INDEX idx_tw_tasks_parent_task ON teamwork.tasks(parent_task);
CREATE INDEX idx_tw_tasks_deleted_at ON teamwork.tasks(deleted_at);
CREATE INDEX idx_tw_tasks_updated_at ON teamwork.tasks(updated_at);
CREATE INDEX idx_tw_task_tags_task_id ON teamwork.task_tags(task_id);
CREATE INDEX idx_tw_task_tags_tag_id ON teamwork.task_tags(tag_id);
CREATE INDEX idx_tw_task_assignees_task_id ON teamwork.task_assignees(task_id);
CREATE INDEX idx_tw_task_assignees_user_id ON teamwork.task_assignees(user_id);
CREATE INDEX idx_tw_user_teams_user_id ON teamwork.user_teams(user_id);
CREATE INDEX idx_tw_user_teams_team_id ON teamwork.user_teams(team_id);

-- Performance indexes
CREATE INDEX idx_tw_tasks_sort_date ON teamwork.tasks(COALESCE(updated_at, created_at) DESC) WHERE deleted_at IS NULL;
CREATE INDEX idx_tw_tasks_deleted_status ON teamwork.tasks(deleted_at, status);
CREATE INDEX idx_tw_tasks_project_status ON teamwork.tasks(project_id, status) WHERE deleted_at IS NULL;
CREATE INDEX idx_tw_tasks_created_by_id ON teamwork.tasks(created_by_id);
CREATE INDEX idx_tw_tasks_updated_by_id ON teamwork.tasks(updated_by_id);
CREATE INDEX idx_tw_users_first_name_lower ON teamwork.users(LOWER(first_name));
CREATE INDEX idx_tw_users_last_name_lower ON teamwork.users(LOWER(last_name));

-- Timelog indexes
CREATE INDEX idx_tw_timelogs_task_id ON teamwork.timelogs(task_id);
CREATE INDEX idx_tw_timelogs_project_id ON teamwork.timelogs(project_id);
CREATE INDEX idx_tw_timelogs_user_id ON teamwork.timelogs(user_id);
CREATE INDEX idx_tw_timelogs_time_logged ON teamwork.timelogs(time_logged);
CREATE INDEX idx_tw_timelogs_deleted ON teamwork.timelogs(deleted);

-- =====================================
-- COMMENTS
-- =====================================

COMMENT ON SCHEMA teamwork IS 'External data from Teamwork project management system';
COMMENT ON TABLE teamwork.tasks IS 'Tasks table from Teamwork API';

