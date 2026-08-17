PRAGMA Yson.AutoConvert;
PRAGMA yson.DisableStrict;
PRAGMA SimpleColumns;
PRAGMA AnsiInForEmptyOrNullableItemsCollections;
PRAGMA yt.InferSchema = '2';

DECLARE $input1 AS String;   -- прогон «вначале»
DECLARE $input2 AS String;   -- прогон «потом»
DECLARE $output1 AS String;  -- сколько речевых ошибок в A и в B, вначале и потом

-- Джойн по input_meta целиком.
-- Речевые ошибки — agg_tov_markup.checkboxes_A / checkboxes_B -> tov_minus_language_errors.

-- Yson нельзя сравнивать напрямую, поэтому ключ — текстовое представление input_meta.
-- если input_meta — обычная строка, а не Yson: RETURN $meta ?? '';
$key = ($meta) -> {
    RETURN CAST(Yson::SerializeText($meta) AS String) ?? '';
};

$le = ($agg, $side) -> {
    RETURN Yson::ConvertToBool(
        Yson::Lookup(Yson::Lookup($agg, $side), 'tov_minus_language_errors')
    ) ?? false;
};

$a = (
    SELECT
        $key(input_meta)                    AS meta_key,
        $le(agg_tov_markup, 'checkboxes_A') AS le_A,
        $le(agg_tov_markup, 'checkboxes_B') AS le_B
    FROM $input1
);

$b = (
    SELECT
        $key(input_meta)                    AS meta_key,
        $le(agg_tov_markup, 'checkboxes_A') AS le_A,
        $le(agg_tov_markup, 'checkboxes_B') AS le_B
    FROM $input2
);

INSERT INTO $output1 WITH TRUNCATE
SELECT
    COUNT(*)              AS rows_total,

    COUNT_IF(a.le_A)      AS A_before,
    COUNT_IF(b.le_A)      AS A_after,
    COUNT_IF(a.le_B)      AS B_before,
    COUNT_IF(b.le_B)      AS B_after,

    COUNT_IF(a.le_A OR a.le_B) AS any_before,
    COUNT_IF(b.le_A OR b.le_B) AS any_after
FROM $a AS a
INNER JOIN $b AS b USING (meta_key);
