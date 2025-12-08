-- =====================================
-- FUNCTIONS AND TRIGGERS (PART 2: HIERARCHY)
-- =====================================

-- =====================================
-- 2. LOCATION HIERARCHY MAINTENANCE
-- =====================================

-- Function to build location path and search_text
CREATE OR REPLACE FUNCTION update_location_hierarchy()
RETURNS TRIGGER AS $$
DECLARE
    parent_rec RECORD;
    parent_path TEXT := '';
    parent_path_ids UUID[] := ARRAY[]::UUID[];
    parent_search TEXT := '';
BEGIN
    -- Set depth based on type
    NEW.depth := CASE NEW.type
        WHEN 'building' THEN 0
        WHEN 'level' THEN 1
        WHEN 'room' THEN 2
    END;
    
    -- If has parent, get parent's data
    IF NEW.parent_id IS NOT NULL THEN
        SELECT path, path_ids, search_text, depth
        INTO parent_rec
        FROM locations
        WHERE id = NEW.parent_id;
        
        IF FOUND THEN
            parent_path := parent_rec.path;
            parent_path_ids := parent_rec.path_ids;
            parent_search := parent_rec.search_text;
            
            -- Verify depth is correct
            IF NEW.depth != parent_rec.depth + 1 THEN
                RAISE EXCEPTION 'Location depth must be parent depth + 1';
            END IF;
        END IF;
    END IF;
    
    -- Build materialized path (using IDs)
    IF parent_path = '' OR parent_path IS NULL THEN
        NEW.path := NEW.id::TEXT;
    ELSE
        NEW.path := parent_path || '.' || NEW.id::TEXT;
    END IF;
    
    -- Build path_ids array
    NEW.path_ids := parent_path_ids || NEW.id;
    
    -- Build search_text (concatenate all parent names)
    IF parent_search = '' OR parent_search IS NULL THEN
        NEW.search_text := NEW.name;
    ELSE
        NEW.search_text := parent_search || ' / ' || NEW.name;
    END IF;
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER location_hierarchy_trigger
    BEFORE INSERT OR UPDATE ON locations
    FOR EACH ROW
    EXECUTE FUNCTION update_location_hierarchy();

-- Function to update children when parent location changes
CREATE OR REPLACE FUNCTION update_location_children()
RETURNS TRIGGER AS $$
BEGIN
    -- If name or path changed, update all children recursively
    IF OLD.name != NEW.name OR OLD.path != NEW.path THEN
        UPDATE locations
        SET db_updated_at = NOW()  -- This will trigger the hierarchy update
        WHERE parent_id = NEW.id;
    END IF;
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER location_children_trigger
    AFTER UPDATE ON locations
    FOR EACH ROW
    WHEN (OLD.name IS DISTINCT FROM NEW.name OR OLD.path IS DISTINCT FROM NEW.path)
    EXECUTE FUNCTION update_location_children();

-- =====================================
-- 3. COST GROUP HIERARCHY MAINTENANCE
-- =====================================

-- Function to build cost group path
CREATE OR REPLACE FUNCTION update_cost_group_path()
RETURNS TRIGGER AS $$
DECLARE
    parent_path TEXT := '';
BEGIN
    -- If has parent, get parent's path
    IF NEW.parent_id IS NOT NULL THEN
        SELECT path INTO parent_path
        FROM cost_groups
        WHERE id = NEW.parent_id;
    END IF;
    
    -- Build materialized path using code (cast to text)
    IF parent_path = '' OR parent_path IS NULL THEN
        NEW.path := NEW.code::TEXT;
    ELSE
        NEW.path := parent_path || '.' || NEW.code::TEXT;
    END IF;
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER cost_group_path_trigger
    BEFORE INSERT OR UPDATE ON cost_groups
    FOR EACH ROW
    EXECUTE FUNCTION update_cost_group_path();

