-- =====================================
-- PROJECT-CONVERSATION AUTO-LINKING
-- =====================================
-- Automatically links conversations to projects based on matching
-- Missive label names with Teamwork project names

-- =====================================
-- 1. PROJECT LINKING RUN TRACKING
-- =====================================

-- Tracks bulk project linking operations
CREATE TABLE project_linking_runs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    status VARCHAR(50) NOT NULL DEFAULT 'running',  -- 'running', 'completed', 'failed'
    total_count INTEGER,
    processed_count INTEGER DEFAULT 0,
    linked_count INTEGER DEFAULT 0,   -- New links created
    skipped_count INTEGER DEFAULT 0,  -- Already linked or no matches
    error_message TEXT,
    started_at TIMESTAMP DEFAULT NOW(),
    completed_at TIMESTAMP
);

CREATE INDEX idx_project_linking_runs_status ON project_linking_runs(status);
CREATE INDEX idx_project_linking_runs_started_at ON project_linking_runs(started_at);

COMMENT ON TABLE project_linking_runs IS 'Tracks status of bulk project-conversation linking operations';

-- =====================================
-- 2. CORE LINKING FUNCTION
-- =====================================

-- Function to link a single conversation to projects based on label matching
-- Checks ALL labels on the conversation and links to ALL matching projects
-- Returns: number of new links created
CREATE OR REPLACE FUNCTION link_projects_for_conversation(p_conversation_id UUID)
RETURNS INTEGER AS $$
DECLARE
    v_label RECORD;
    v_project RECORD;
    v_links_created INTEGER := 0;
    v_existing_count INTEGER;
BEGIN
    -- Loop through all labels on this conversation
    FOR v_label IN 
        SELECT sl.id as label_id, sl.name as label_name
        FROM missive.conversation_labels cl
        JOIN missive.shared_labels sl ON cl.label_id = sl.id
        WHERE cl.conversation_id = p_conversation_id
    LOOP
        -- Find projects whose name matches this label (case-insensitive)
        FOR v_project IN 
            SELECT id, name
            FROM teamwork.projects
            WHERE LOWER(name) = LOWER(v_label.label_name)
        LOOP
            -- Check if link already exists
            SELECT COUNT(*) INTO v_existing_count
            FROM project_conversations
            WHERE m_conversation_id = p_conversation_id
              AND tw_project_id = v_project.id;
            
            IF v_existing_count = 0 THEN
                -- Create the link
                INSERT INTO project_conversations (
                    m_conversation_id,
                    tw_project_id,
                    source,
                    source_label_name,
                    assigned_at
                ) VALUES (
                    p_conversation_id,
                    v_project.id,
                    'auto_label',
                    v_label.label_name,
                    NOW()
                );
                
                v_links_created := v_links_created + 1;
            END IF;
        END LOOP;
    END LOOP;
    
    RETURN v_links_created;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION link_projects_for_conversation(UUID) IS 'Links a conversation to all projects whose names match conversation labels';

-- =====================================
-- 3. TRIGGER FUNCTIONS
-- =====================================

-- Trigger function for new conversations
CREATE OR REPLACE FUNCTION trigger_link_projects_on_conversation_insert()
RETURNS TRIGGER AS $$
BEGIN
    -- Auto-link projects when a conversation is inserted
    PERFORM link_projects_for_conversation(NEW.id);
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Trigger function for conversation labels being added
CREATE OR REPLACE FUNCTION trigger_link_projects_on_label_add()
RETURNS TRIGGER AS $$
BEGIN
    -- Auto-link projects when a label is added to a conversation
    PERFORM link_projects_for_conversation(NEW.conversation_id);
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Create triggers
CREATE TRIGGER auto_link_projects_on_conversation_insert
    AFTER INSERT ON missive.conversations
    FOR EACH ROW
    EXECUTE FUNCTION trigger_link_projects_on_conversation_insert();

CREATE TRIGGER auto_link_projects_on_label_add
    AFTER INSERT ON missive.conversation_labels
    FOR EACH ROW
    EXECUTE FUNCTION trigger_link_projects_on_label_add();

-- =====================================
-- 4. BULK LINKING FUNCTIONS (for UI button)
-- =====================================

-- Main function to run project linking on all existing conversations
-- Returns the run ID for status tracking
CREATE OR REPLACE FUNCTION rerun_all_project_conversation_linking()
RETURNS UUID 
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_run_id UUID;
    v_total_count INTEGER;
    v_processed INTEGER := 0;
    v_linked INTEGER := 0;
    v_skipped INTEGER := 0;
    v_record RECORD;
    v_result INTEGER;
BEGIN
    -- Create a new run record
    INSERT INTO project_linking_runs (status, started_at)
    VALUES ('running', NOW())
    RETURNING id INTO v_run_id;

    -- Count total conversations that have labels
    SELECT COUNT(DISTINCT cl.conversation_id) INTO v_total_count
    FROM missive.conversation_labels cl;

    -- Update total count
    UPDATE project_linking_runs SET total_count = v_total_count WHERE id = v_run_id;

    -- Process all conversations that have labels
    FOR v_record IN 
        SELECT DISTINCT cl.conversation_id
        FROM missive.conversation_labels cl
        ORDER BY cl.conversation_id
    LOOP
        BEGIN
            v_result := link_projects_for_conversation(v_record.conversation_id);
            v_processed := v_processed + 1;
            
            IF v_result > 0 THEN
                v_linked := v_linked + v_result;
            ELSE
                v_skipped := v_skipped + 1;
            END IF;
            
            -- Update progress every 100 items
            IF v_processed % 100 = 0 THEN
                UPDATE project_linking_runs 
                SET processed_count = v_processed,
                    linked_count = v_linked,
                    skipped_count = v_skipped
                WHERE id = v_run_id;
            END IF;
        EXCEPTION WHEN OTHERS THEN
            -- Log error but continue processing
            RAISE NOTICE 'Error processing conversation %: %', v_record.conversation_id, SQLERRM;
            v_processed := v_processed + 1;
            v_skipped := v_skipped + 1;
        END;
    END LOOP;

    -- Mark as completed
    UPDATE project_linking_runs 
    SET 
        status = 'completed',
        processed_count = v_processed,
        linked_count = v_linked,
        skipped_count = v_skipped,
        completed_at = NOW()
    WHERE id = v_run_id;

    RETURN v_run_id;
END;
$$ LANGUAGE plpgsql;

-- Function to check project linking run status
CREATE OR REPLACE FUNCTION get_project_linking_run_status(p_run_id UUID)
RETURNS TABLE (
    id UUID,
    status VARCHAR(50),
    total_count INTEGER,
    processed_count INTEGER,
    linked_count INTEGER,
    skipped_count INTEGER,
    progress_percent NUMERIC,
    started_at TIMESTAMP,
    completed_at TIMESTAMP,
    error_message TEXT
)
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    RETURN QUERY
    SELECT 
        plr.id,
        plr.status,
        plr.total_count,
        plr.processed_count,
        plr.linked_count,
        plr.skipped_count,
        CASE 
            WHEN plr.total_count > 0 THEN 
                ROUND((plr.processed_count::NUMERIC / plr.total_count::NUMERIC) * 100, 1)
            ELSE 0
        END AS progress_percent,
        plr.started_at,
        plr.completed_at,
        plr.error_message
    FROM project_linking_runs plr
    WHERE plr.id = p_run_id;
END;
$$ LANGUAGE plpgsql STABLE;

-- Function to get the latest project linking run
CREATE OR REPLACE FUNCTION get_latest_project_linking_run()
RETURNS TABLE (
    id UUID,
    status VARCHAR(50),
    total_count INTEGER,
    processed_count INTEGER,
    linked_count INTEGER,
    skipped_count INTEGER,
    progress_percent NUMERIC,
    started_at TIMESTAMP,
    completed_at TIMESTAMP,
    error_message TEXT
)
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    RETURN QUERY
    SELECT 
        plr.id,
        plr.status,
        plr.total_count,
        plr.processed_count,
        plr.linked_count,
        plr.skipped_count,
        CASE 
            WHEN plr.total_count > 0 THEN 
                ROUND((plr.processed_count::NUMERIC / plr.total_count::NUMERIC) * 100, 1)
            ELSE 0
        END AS progress_percent,
        plr.started_at,
        plr.completed_at,
        plr.error_message
    FROM project_linking_runs plr
    ORDER BY plr.started_at DESC
    LIMIT 1;
END;
$$ LANGUAGE plpgsql STABLE;

-- =====================================
-- COMMENTS
-- =====================================

COMMENT ON FUNCTION link_projects_for_conversation(UUID) IS 'Links a conversation to all projects matching its label names';
COMMENT ON FUNCTION rerun_all_project_conversation_linking() IS 'Re-runs project linking on all conversations with labels, returns run ID for tracking';
COMMENT ON FUNCTION get_project_linking_run_status(UUID) IS 'Gets status of a project linking run by ID';
COMMENT ON FUNCTION get_latest_project_linking_run() IS 'Gets the most recent project linking run status';

