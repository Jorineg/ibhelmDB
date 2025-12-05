-- =====================================
-- UNIFIED PERSON AUTO-CREATION
-- =====================================
-- Automatically creates unified persons when contacts/users are added
-- and links them to the source system (Missive or Teamwork)

-- =====================================
-- 1. PERSON LINKING RUN TRACKING
-- =====================================

-- Similar to extraction_runs, tracks bulk person linking operations
CREATE TABLE person_linking_runs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    status VARCHAR(50) NOT NULL DEFAULT 'running',  -- 'running', 'completed', 'failed'
    total_count INTEGER,
    processed_count INTEGER DEFAULT 0,
    created_count INTEGER DEFAULT 0,  -- New unified persons created
    linked_count INTEGER DEFAULT 0,   -- Links to existing unified persons created
    skipped_count INTEGER DEFAULT 0,  -- Already linked items skipped
    error_message TEXT,
    started_at TIMESTAMP DEFAULT NOW(),
    completed_at TIMESTAMP
);

CREATE INDEX idx_person_linking_runs_status ON person_linking_runs(status);
CREATE INDEX idx_person_linking_runs_started_at ON person_linking_runs(started_at);

COMMENT ON TABLE person_linking_runs IS 'Tracks status of bulk person linking operations';

-- =====================================
-- 2. CORE LINKING FUNCTIONS
-- =====================================

-- Function to create/link unified person from a Missive contact
-- Returns: 'created', 'linked', or 'skipped'
CREATE OR REPLACE FUNCTION link_person_from_missive_contact(p_contact_id INTEGER)
RETURNS TEXT AS $$
DECLARE
    v_contact RECORD;
    v_existing_person_id UUID;
    v_existing_link_count INTEGER;
    v_new_person_id UUID;
BEGIN
    -- Get contact info
    SELECT id, name, email
    INTO v_contact
    FROM missive.contacts
    WHERE id = p_contact_id;
    
    IF NOT FOUND THEN
        RETURN 'skipped';  -- Contact doesn't exist
    END IF;
    
    -- Check if this contact already has a link
    SELECT COUNT(*) INTO v_existing_link_count
    FROM unified_person_links
    WHERE m_contact_id = p_contact_id;
    
    IF v_existing_link_count > 0 THEN
        RETURN 'skipped';  -- Already linked
    END IF;
    
    -- Check if a unified person with this email already exists
    IF v_contact.email IS NOT NULL AND v_contact.email != '' THEN
        SELECT id INTO v_existing_person_id
        FROM unified_persons
        WHERE LOWER(primary_email) = LOWER(v_contact.email)
        LIMIT 1;
    END IF;
    
    IF v_existing_person_id IS NOT NULL THEN
        -- Link to existing person (don't update display_name if already set)
        INSERT INTO unified_person_links (unified_person_id, m_contact_id, link_type)
        VALUES (v_existing_person_id, p_contact_id, 'auto_email');
        
        RETURN 'linked';
    ELSE
        -- Create new unified person
        INSERT INTO unified_persons (display_name, primary_email)
        VALUES (
            COALESCE(NULLIF(v_contact.name, ''), v_contact.email),
            v_contact.email
        )
        RETURNING id INTO v_new_person_id;
        
        -- Create link
        INSERT INTO unified_person_links (unified_person_id, m_contact_id, link_type)
        VALUES (v_new_person_id, p_contact_id, 'auto_email');
        
        RETURN 'created';
    END IF;
END;
$$ LANGUAGE plpgsql;

-- Function to create/link unified person from a Teamwork user
-- Returns: 'created', 'linked', or 'skipped'
CREATE OR REPLACE FUNCTION link_person_from_teamwork_user(p_user_id INTEGER)
RETURNS TEXT AS $$
DECLARE
    v_user RECORD;
    v_existing_person_id UUID;
    v_existing_link_count INTEGER;
    v_new_person_id UUID;
    v_display_name TEXT;
BEGIN
    -- Get user info
    SELECT id, first_name, last_name, email
    INTO v_user
    FROM teamwork.users
    WHERE id = p_user_id;
    
    IF NOT FOUND THEN
        RETURN 'skipped';  -- User doesn't exist
    END IF;
    
    -- Check if this user already has a link
    SELECT COUNT(*) INTO v_existing_link_count
    FROM unified_person_links
    WHERE tw_user_id = p_user_id;
    
    IF v_existing_link_count > 0 THEN
        RETURN 'skipped';  -- Already linked
    END IF;
    
    -- Build display name from first + last name
    v_display_name := TRIM(COALESCE(v_user.first_name, '') || ' ' || COALESCE(v_user.last_name, ''));
    IF v_display_name = '' THEN
        v_display_name := v_user.email;
    END IF;
    
    -- Check if a unified person with this email already exists
    IF v_user.email IS NOT NULL AND v_user.email != '' THEN
        SELECT id INTO v_existing_person_id
        FROM unified_persons
        WHERE LOWER(primary_email) = LOWER(v_user.email)
        LIMIT 1;
    END IF;
    
    IF v_existing_person_id IS NOT NULL THEN
        -- Link to existing person (don't update display_name if already set)
        INSERT INTO unified_person_links (unified_person_id, tw_user_id, link_type)
        VALUES (v_existing_person_id, p_user_id, 'auto_email');
        
        RETURN 'linked';
    ELSE
        -- Create new unified person
        INSERT INTO unified_persons (display_name, primary_email)
        VALUES (v_display_name, v_user.email)
        RETURNING id INTO v_new_person_id;
        
        -- Create link
        INSERT INTO unified_person_links (unified_person_id, tw_user_id, link_type)
        VALUES (v_new_person_id, p_user_id, 'auto_email');
        
        RETURN 'created';
    END IF;
END;
$$ LANGUAGE plpgsql;

-- =====================================
-- 3. TRIGGER FUNCTIONS
-- =====================================

-- Trigger function for Missive contacts
CREATE OR REPLACE FUNCTION trigger_link_person_from_missive_contact()
RETURNS TRIGGER AS $$
BEGIN
    -- Auto-link person when a contact is inserted
    PERFORM link_person_from_missive_contact(NEW.id);
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Trigger function for Teamwork users
CREATE OR REPLACE FUNCTION trigger_link_person_from_teamwork_user()
RETURNS TRIGGER AS $$
BEGIN
    -- Auto-link person when a user is inserted
    PERFORM link_person_from_teamwork_user(NEW.id);
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Create triggers
CREATE TRIGGER auto_link_person_on_missive_contact
    AFTER INSERT ON missive.contacts
    FOR EACH ROW
    EXECUTE FUNCTION trigger_link_person_from_missive_contact();

CREATE TRIGGER auto_link_person_on_teamwork_user
    AFTER INSERT ON teamwork.users
    FOR EACH ROW
    EXECUTE FUNCTION trigger_link_person_from_teamwork_user();

-- =====================================
-- 4. BULK LINKING FUNCTIONS (for UI button)
-- =====================================

-- Main function to run person linking on all existing contacts and users
-- Returns the run ID for status tracking
CREATE OR REPLACE FUNCTION rerun_all_person_linking()
RETURNS UUID 
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_run_id UUID;
    v_total_count INTEGER;
    v_processed INTEGER := 0;
    v_created INTEGER := 0;
    v_linked INTEGER := 0;
    v_skipped INTEGER := 0;
    v_record RECORD;
    v_result TEXT;
BEGIN
    -- Create a new run record
    INSERT INTO person_linking_runs (status, started_at)
    VALUES ('running', NOW())
    RETURNING id INTO v_run_id;

    -- Count total items (missive contacts + teamwork users)
    SELECT 
        (SELECT COUNT(*) FROM missive.contacts) + 
        (SELECT COUNT(*) FROM teamwork.users)
    INTO v_total_count;

    -- Update total count
    UPDATE person_linking_runs SET total_count = v_total_count WHERE id = v_run_id;

    -- Process all Missive contacts
    FOR v_record IN 
        SELECT id FROM missive.contacts ORDER BY id
    LOOP
        BEGIN
            v_result := link_person_from_missive_contact(v_record.id);
            v_processed := v_processed + 1;
            
            IF v_result = 'created' THEN
                v_created := v_created + 1;
            ELSIF v_result = 'linked' THEN
                v_linked := v_linked + 1;
            ELSE
                v_skipped := v_skipped + 1;
            END IF;
            
            -- Update progress every 100 items
            IF v_processed % 100 = 0 THEN
                UPDATE person_linking_runs 
                SET processed_count = v_processed,
                    created_count = v_created,
                    linked_count = v_linked,
                    skipped_count = v_skipped
                WHERE id = v_run_id;
            END IF;
        EXCEPTION WHEN OTHERS THEN
            -- Log error but continue processing
            RAISE NOTICE 'Error processing missive contact %: %', v_record.id, SQLERRM;
            v_processed := v_processed + 1;
            v_skipped := v_skipped + 1;
        END;
    END LOOP;

    -- Process all Teamwork users
    FOR v_record IN 
        SELECT id FROM teamwork.users ORDER BY id
    LOOP
        BEGIN
            v_result := link_person_from_teamwork_user(v_record.id);
            v_processed := v_processed + 1;
            
            IF v_result = 'created' THEN
                v_created := v_created + 1;
            ELSIF v_result = 'linked' THEN
                v_linked := v_linked + 1;
            ELSE
                v_skipped := v_skipped + 1;
            END IF;
            
            -- Update progress every 100 items
            IF v_processed % 100 = 0 THEN
                UPDATE person_linking_runs 
                SET processed_count = v_processed,
                    created_count = v_created,
                    linked_count = v_linked,
                    skipped_count = v_skipped
                WHERE id = v_run_id;
            END IF;
        EXCEPTION WHEN OTHERS THEN
            -- Log error but continue processing
            RAISE NOTICE 'Error processing teamwork user %: %', v_record.id, SQLERRM;
            v_processed := v_processed + 1;
            v_skipped := v_skipped + 1;
        END;
    END LOOP;

    -- Mark as completed
    UPDATE person_linking_runs 
    SET 
        status = 'completed',
        processed_count = v_processed,
        created_count = v_created,
        linked_count = v_linked,
        skipped_count = v_skipped,
        completed_at = NOW()
    WHERE id = v_run_id;

    RETURN v_run_id;
END;
$$ LANGUAGE plpgsql;

-- Function to check person linking run status
CREATE OR REPLACE FUNCTION get_person_linking_run_status(p_run_id UUID)
RETURNS TABLE (
    id UUID,
    status VARCHAR(50),
    total_count INTEGER,
    processed_count INTEGER,
    created_count INTEGER,
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
        plr.created_count,
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
    FROM person_linking_runs plr
    WHERE plr.id = p_run_id;
END;
$$ LANGUAGE plpgsql STABLE;

-- Function to get the latest person linking run
CREATE OR REPLACE FUNCTION get_latest_person_linking_run()
RETURNS TABLE (
    id UUID,
    status VARCHAR(50),
    total_count INTEGER,
    processed_count INTEGER,
    created_count INTEGER,
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
        plr.created_count,
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
    FROM person_linking_runs plr
    ORDER BY plr.started_at DESC
    LIMIT 1;
END;
$$ LANGUAGE plpgsql STABLE;

-- =====================================
-- COMMENTS
-- =====================================

COMMENT ON FUNCTION link_person_from_missive_contact(INTEGER) IS 'Creates or links a unified person from a Missive contact';
COMMENT ON FUNCTION link_person_from_teamwork_user(INTEGER) IS 'Creates or links a unified person from a Teamwork user';
COMMENT ON FUNCTION rerun_all_person_linking() IS 'Re-runs person linking on all contacts and users, returns run ID for tracking';
COMMENT ON FUNCTION get_person_linking_run_status(UUID) IS 'Gets status of a person linking run by ID';
COMMENT ON FUNCTION get_latest_person_linking_run() IS 'Gets the most recent person linking run status';

