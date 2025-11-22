-- =====================================
-- CUSTOM TYPES AND ENUMS
-- =====================================

-- Party type for the unified party model
CREATE TYPE party_type AS ENUM ('company', 'person');

-- Location type for hierarchical location structure
CREATE TYPE location_type AS ENUM ('building', 'level', 'room');

-- Task extension type for ibhelm semantics
CREATE TYPE task_extension_type AS ENUM ('todo', 'info_item');

COMMENT ON TYPE party_type IS 'Distinguishes between companies and persons in the unified party model';
COMMENT ON TYPE location_type IS 'Hierarchical location levels: building > level > room';
COMMENT ON TYPE task_extension_type IS 'Extends Teamwork tasks with ibhelm-specific semantics (Decorator Pattern)';

