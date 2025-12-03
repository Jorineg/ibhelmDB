-- =====================================
-- CUSTOM TYPES AND ENUMS
-- =====================================

-- Task extension type for ibhelm semantics
CREATE TYPE task_extension_type AS ENUM ('todo', 'info_item');

-- Location type for hierarchical locations
CREATE TYPE location_type AS ENUM ('building', 'level', 'room');

COMMENT ON TYPE task_extension_type IS 'Extends Teamwork tasks with ibhelm-specific semantics (Decorator Pattern)';
COMMENT ON TYPE location_type IS 'Hierarchical location types: building > level > room';
