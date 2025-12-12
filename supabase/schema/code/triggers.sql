-- =====================================
-- ALL TRIGGERS (IDEMPOTENT)
-- =====================================
-- Pattern: DROP TRIGGER IF EXISTS + CREATE TRIGGER
-- This file can be safely re-run

-- =====================================
-- 1. AUTO-UPDATE TIMESTAMPS
-- =====================================

-- Public schema
DROP TRIGGER IF EXISTS update_unified_persons_updated_at ON unified_persons;
CREATE TRIGGER update_unified_persons_updated_at BEFORE UPDATE ON unified_persons
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

DROP TRIGGER IF EXISTS update_unified_person_links_updated_at ON unified_person_links;
CREATE TRIGGER update_unified_person_links_updated_at BEFORE UPDATE ON unified_person_links
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

DROP TRIGGER IF EXISTS update_project_extensions_updated_at ON project_extensions;
CREATE TRIGGER update_project_extensions_updated_at BEFORE UPDATE ON project_extensions
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

DROP TRIGGER IF EXISTS update_locations_updated_at ON locations;
CREATE TRIGGER update_locations_updated_at BEFORE UPDATE ON locations
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

DROP TRIGGER IF EXISTS update_cost_groups_updated_at ON cost_groups;
CREATE TRIGGER update_cost_groups_updated_at BEFORE UPDATE ON cost_groups
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

DROP TRIGGER IF EXISTS update_files_updated_at ON files;
CREATE TRIGGER update_files_updated_at BEFORE UPDATE ON files
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

DROP TRIGGER IF EXISTS update_craft_documents_updated_at ON craft_documents;
CREATE TRIGGER update_craft_documents_updated_at BEFORE UPDATE ON craft_documents
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

DROP TRIGGER IF EXISTS update_task_extensions_updated_at ON task_extensions;
CREATE TRIGGER update_task_extensions_updated_at BEFORE UPDATE ON task_extensions
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

DROP TRIGGER IF EXISTS update_task_types_updated_at ON task_types;
CREATE TRIGGER update_task_types_updated_at BEFORE UPDATE ON task_types
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- Teamwork schema
DROP TRIGGER IF EXISTS update_tw_companies_updated_at ON teamwork.companies;
CREATE TRIGGER update_tw_companies_updated_at BEFORE UPDATE ON teamwork.companies
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

DROP TRIGGER IF EXISTS update_tw_users_updated_at ON teamwork.users;
CREATE TRIGGER update_tw_users_updated_at BEFORE UPDATE ON teamwork.users
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

DROP TRIGGER IF EXISTS update_tw_teams_updated_at ON teamwork.teams;
CREATE TRIGGER update_tw_teams_updated_at BEFORE UPDATE ON teamwork.teams
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

DROP TRIGGER IF EXISTS update_tw_projects_updated_at ON teamwork.projects;
CREATE TRIGGER update_tw_projects_updated_at BEFORE UPDATE ON teamwork.projects
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

DROP TRIGGER IF EXISTS update_tw_tasklists_updated_at ON teamwork.tasklists;
CREATE TRIGGER update_tw_tasklists_updated_at BEFORE UPDATE ON teamwork.tasklists
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

DROP TRIGGER IF EXISTS update_tw_tasks_updated_at ON teamwork.tasks;
CREATE TRIGGER update_tw_tasks_updated_at BEFORE UPDATE ON teamwork.tasks
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- Missive schema
DROP TRIGGER IF EXISTS update_m_contacts_updated_at ON missive.contacts;
CREATE TRIGGER update_m_contacts_updated_at BEFORE UPDATE ON missive.contacts
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

DROP TRIGGER IF EXISTS update_m_users_updated_at ON missive.users;
CREATE TRIGGER update_m_users_updated_at BEFORE UPDATE ON missive.users
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

DROP TRIGGER IF EXISTS update_m_teams_updated_at ON missive.teams;
CREATE TRIGGER update_m_teams_updated_at BEFORE UPDATE ON missive.teams
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

DROP TRIGGER IF EXISTS update_m_conversations_updated_at ON missive.conversations;
CREATE TRIGGER update_m_conversations_updated_at BEFORE UPDATE ON missive.conversations
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

DROP TRIGGER IF EXISTS update_m_messages_updated_at ON missive.messages;
CREATE TRIGGER update_m_messages_updated_at BEFORE UPDATE ON missive.messages
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- =====================================
-- 2. HIERARCHY TRIGGERS
-- =====================================

DROP TRIGGER IF EXISTS location_hierarchy_trigger ON locations;
CREATE TRIGGER location_hierarchy_trigger BEFORE INSERT OR UPDATE ON locations
    FOR EACH ROW EXECUTE FUNCTION update_location_hierarchy();

DROP TRIGGER IF EXISTS location_children_trigger ON locations;
CREATE TRIGGER location_children_trigger AFTER UPDATE ON locations
    FOR EACH ROW WHEN (OLD.name IS DISTINCT FROM NEW.name OR OLD.path IS DISTINCT FROM NEW.path)
    EXECUTE FUNCTION update_location_children();

DROP TRIGGER IF EXISTS cost_group_path_trigger ON cost_groups;
CREATE TRIGGER cost_group_path_trigger BEFORE INSERT OR UPDATE ON cost_groups
    FOR EACH ROW EXECUTE FUNCTION update_cost_group_path();

-- =====================================
-- 3. TASK TYPE EXTRACTION TRIGGERS
-- =====================================

DROP TRIGGER IF EXISTS extract_task_type_on_task_change ON teamwork.tasks;
CREATE TRIGGER extract_task_type_on_task_change AFTER INSERT OR UPDATE ON teamwork.tasks
    FOR EACH ROW EXECUTE FUNCTION trigger_extract_task_type();

DROP TRIGGER IF EXISTS extract_task_type_on_tags_change ON teamwork.task_tags;
CREATE TRIGGER extract_task_type_on_tags_change AFTER INSERT OR UPDATE OR DELETE ON teamwork.task_tags
    FOR EACH ROW EXECUTE FUNCTION trigger_task_tags_extract_type();

-- =====================================
-- 4. UNIFIED PERSON AUTO-CREATION TRIGGERS
-- =====================================

DROP TRIGGER IF EXISTS auto_link_person_on_missive_contact ON missive.contacts;
CREATE TRIGGER auto_link_person_on_missive_contact AFTER INSERT ON missive.contacts
    FOR EACH ROW EXECUTE FUNCTION trigger_link_person_from_missive_contact();

DROP TRIGGER IF EXISTS auto_link_person_on_teamwork_user ON teamwork.users;
CREATE TRIGGER auto_link_person_on_teamwork_user AFTER INSERT ON teamwork.users
    FOR EACH ROW EXECUTE FUNCTION trigger_link_person_from_teamwork_user();

-- =====================================
-- 5. LOCATION AUTO-EXTRACTION TRIGGERS
-- =====================================

DROP TRIGGER IF EXISTS extract_locations_on_task_tags_change ON teamwork.task_tags;
CREATE TRIGGER extract_locations_on_task_tags_change AFTER INSERT OR UPDATE OR DELETE ON teamwork.task_tags
    FOR EACH ROW EXECUTE FUNCTION trigger_extract_locations_for_task();

DROP TRIGGER IF EXISTS extract_locations_on_conv_labels_change ON missive.conversation_labels;
CREATE TRIGGER extract_locations_on_conv_labels_change AFTER INSERT OR UPDATE OR DELETE ON missive.conversation_labels
    FOR EACH ROW EXECUTE FUNCTION trigger_extract_locations_for_conversation();

-- =====================================
-- 5b. COST GROUP AUTO-EXTRACTION TRIGGERS
-- =====================================

DROP TRIGGER IF EXISTS extract_cost_groups_on_task_tags_change ON teamwork.task_tags;
CREATE TRIGGER extract_cost_groups_on_task_tags_change AFTER INSERT OR UPDATE OR DELETE ON teamwork.task_tags
    FOR EACH ROW EXECUTE FUNCTION trigger_extract_cost_groups_for_task();

DROP TRIGGER IF EXISTS extract_cost_groups_on_conv_labels_change ON missive.conversation_labels;
CREATE TRIGGER extract_cost_groups_on_conv_labels_change AFTER INSERT OR UPDATE OR DELETE ON missive.conversation_labels
    FOR EACH ROW EXECUTE FUNCTION trigger_extract_cost_groups_for_conversation();

-- =====================================
-- 6. PROJECT-CONVERSATION AUTO-LINKING TRIGGERS
-- =====================================

DROP TRIGGER IF EXISTS auto_link_projects_on_conversation_insert ON missive.conversations;
CREATE TRIGGER auto_link_projects_on_conversation_insert AFTER INSERT ON missive.conversations
    FOR EACH ROW EXECUTE FUNCTION trigger_link_projects_on_conversation_insert();

DROP TRIGGER IF EXISTS auto_link_projects_on_label_add ON missive.conversation_labels;
DROP TRIGGER IF EXISTS auto_link_projects_on_label_change ON missive.conversation_labels;
CREATE TRIGGER auto_link_projects_on_label_change AFTER INSERT OR UPDATE OR DELETE ON missive.conversation_labels
    FOR EACH ROW EXECUTE FUNCTION trigger_link_projects_on_label_change();

-- =====================================
-- 6. INVOLVED PERSONS TRIGGERS
-- =====================================

DROP TRIGGER IF EXISTS trg_task_involvement ON teamwork.tasks;
CREATE TRIGGER trg_task_involvement AFTER INSERT OR UPDATE OR DELETE ON teamwork.tasks
    FOR EACH ROW EXECUTE FUNCTION trigger_refresh_task_involvement();

DROP TRIGGER IF EXISTS trg_task_assignee_involvement ON teamwork.task_assignees;
CREATE TRIGGER trg_task_assignee_involvement AFTER INSERT OR UPDATE OR DELETE ON teamwork.task_assignees
    FOR EACH ROW EXECUTE FUNCTION trigger_refresh_task_assignee_involvement();

DROP TRIGGER IF EXISTS trg_message_involvement ON missive.messages;
CREATE TRIGGER trg_message_involvement AFTER INSERT OR UPDATE OR DELETE ON missive.messages
    FOR EACH ROW EXECUTE FUNCTION trigger_refresh_message_involvement();

DROP TRIGGER IF EXISTS trg_recipient_involvement ON missive.message_recipients;
CREATE TRIGGER trg_recipient_involvement AFTER INSERT OR UPDATE OR DELETE ON missive.message_recipients
    FOR EACH ROW EXECUTE FUNCTION trigger_refresh_recipient_involvement();

DROP TRIGGER IF EXISTS trg_conversation_assignee_involvement ON missive.conversation_assignees;
CREATE TRIGGER trg_conversation_assignee_involvement AFTER INSERT OR UPDATE OR DELETE ON missive.conversation_assignees
    FOR EACH ROW EXECUTE FUNCTION trigger_refresh_conversation_involvement();

DROP TRIGGER IF EXISTS trg_conversation_author_involvement ON missive.conversation_authors;
CREATE TRIGGER trg_conversation_author_involvement AFTER INSERT OR UPDATE OR DELETE ON missive.conversation_authors
    FOR EACH ROW EXECUTE FUNCTION trigger_refresh_conversation_involvement();

DROP TRIGGER IF EXISTS trg_conversation_comment_involvement ON missive.conversation_comments;
CREATE TRIGGER trg_conversation_comment_involvement AFTER INSERT OR UPDATE OR DELETE ON missive.conversation_comments
    FOR EACH ROW EXECUTE FUNCTION trigger_refresh_conversation_involvement();

-- =====================================
-- 7. FILE METADATA EXTRACTION TRIGGERS
-- =====================================

DROP TRIGGER IF EXISTS extract_file_metadata_on_insert ON files;
CREATE TRIGGER extract_file_metadata_on_insert AFTER INSERT ON files
    FOR EACH ROW EXECUTE FUNCTION trigger_extract_file_metadata();

DROP TRIGGER IF EXISTS extract_file_metadata_on_update ON files;
CREATE TRIGGER extract_file_metadata_on_update AFTER UPDATE OF storage_path, filename ON files
    FOR EACH ROW EXECUTE FUNCTION trigger_extract_file_metadata();

-- =====================================
-- 8. MATERIALIZED VIEW STALENESS TRIGGERS
-- =====================================

DROP TRIGGER IF EXISTS trg_task_assignees_mv_stale ON teamwork.task_assignees;
CREATE TRIGGER trg_task_assignees_mv_stale AFTER INSERT OR UPDATE OR DELETE ON teamwork.task_assignees
    FOR EACH STATEMENT EXECUTE FUNCTION trigger_mark_mv_stale('mv_task_assignees_agg');

DROP TRIGGER IF EXISTS trg_task_tags_mv_stale ON teamwork.task_tags;
CREATE TRIGGER trg_task_tags_mv_stale AFTER INSERT OR UPDATE OR DELETE ON teamwork.task_tags
    FOR EACH STATEMENT EXECUTE FUNCTION trigger_mark_mv_stale('mv_task_tags_agg');

DROP TRIGGER IF EXISTS trg_message_recipients_mv_stale ON missive.message_recipients;
CREATE TRIGGER trg_message_recipients_mv_stale AFTER INSERT OR UPDATE OR DELETE ON missive.message_recipients
    FOR EACH STATEMENT EXECUTE FUNCTION trigger_mark_mv_stale('mv_message_recipients_agg');

DROP TRIGGER IF EXISTS trg_attachments_mv_stale ON missive.attachments;
CREATE TRIGGER trg_attachments_mv_stale AFTER INSERT OR UPDATE OR DELETE ON missive.attachments
    FOR EACH STATEMENT EXECUTE FUNCTION trigger_mark_mv_stale('mv_message_attachments_agg');

DROP TRIGGER IF EXISTS trg_conv_labels_mv_stale ON missive.conversation_labels;
CREATE TRIGGER trg_conv_labels_mv_stale AFTER INSERT OR UPDATE OR DELETE ON missive.conversation_labels
    FOR EACH STATEMENT EXECUTE FUNCTION trigger_mark_mv_stale('mv_conversation_labels_agg');

DROP TRIGGER IF EXISTS trg_conv_comments_mv_stale ON missive.conversation_comments;
CREATE TRIGGER trg_conv_comments_mv_stale AFTER INSERT OR UPDATE OR DELETE ON missive.conversation_comments
    FOR EACH STATEMENT EXECUTE FUNCTION trigger_mark_mv_stale('mv_conversation_comments_agg');

-- =====================================
-- 9. ATTACHMENT DOWNLOAD QUEUE TRIGGER
-- =====================================

DROP TRIGGER IF EXISTS trg_queue_attachment_download ON missive.attachments;
CREATE TRIGGER trg_queue_attachment_download AFTER INSERT OR UPDATE ON missive.attachments
    FOR EACH ROW EXECUTE FUNCTION trigger_queue_attachment_download();

