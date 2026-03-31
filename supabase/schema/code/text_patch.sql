-- Generic search-and-replace patch function for AI text editing.
-- Patch format: one or more blocks of:
--   <<<SEARCH
--   exact text to find (must appear exactly once)
--   ===REPLACE
--   replacement text
--   >>>
-- Blocks are applied sequentially; later blocks see results of earlier ones.

CREATE OR REPLACE FUNCTION apply_text_patch(
  content TEXT,
  patch TEXT
) RETURNS TEXT
LANGUAGE plpgsql IMMUTABLE STRICT AS $$
DECLARE
  result TEXT := content;
  match_arr TEXT[];
  search_str TEXT;
  replace_str TEXT;
  occurrences INT;
  block_num INT := 0;
BEGIN
  FOR match_arr IN
    SELECT regexp_matches(
      patch,
      '<<<SEARCH\n(.+?)\n===REPLACE\n?(.*?)\n?>>>',
      'gs'
    )
  LOOP
    block_num := block_num + 1;
    search_str := match_arr[1];
    replace_str := COALESCE(match_arr[2], '');

    occurrences := array_length(string_to_array(result, search_str), 1) - 1;

    IF occurrences = 0 THEN
      RAISE EXCEPTION 'apply_text_patch block %: search text not found: "%"',
        block_num, left(search_str, 200);
    END IF;

    IF occurrences > 1 THEN
      RAISE EXCEPTION 'apply_text_patch block %: search text matches % times (must be unique): "%"',
        block_num, occurrences, left(search_str, 200);
    END IF;

    result := replace(result, search_str, replace_str);
  END LOOP;

  IF block_num = 0 THEN
    RAISE EXCEPTION 'apply_text_patch: no valid patch blocks found in input';
  END IF;

  RETURN result;
END;
$$;
