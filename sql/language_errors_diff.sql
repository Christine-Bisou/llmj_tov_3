PRAGMA Yson.AutoConvert;
PRAGMA yson.DisableStrict;
PRAGMA SimpleColumns;
PRAGMA AnsiInForEmptyOrNullableItemsCollections;
PRAGMA yt.InferSchema = '2';

DECLARE $input1 AS String;   -- прогон «до»
DECLARE $input2 AS String;   -- прогон «после»
DECLARE $output1 AS String;  -- построчный диф по чекбоксу речевых ошибок
DECLARE $output2 AS String;  -- сводка одной строкой

-- Джойн идёт по input_meta.instruct_id, сравнивается один чекбокс —
-- agg_tov_markup.checkboxes_A/checkboxes_B -> tov_minus_language_errors
-- (в разметке это и есть «речевые ошибки», маркер language_errors).

-- Если input_meta лежит обычной структурой, а не Yson,
-- замени тело на: RETURN COALESCE(CAST($meta.instruct_id AS String), '');
$iid = ($meta) -> {
    RETURN Yson::ConvertToString(Yson::Lookup($meta, 'instruct_id')) ?? '';
};

-- отсутствующий чекбокс считаем false: «не отмечен» = ошибок нет
$le = ($agg, $side) -> {
    RETURN Yson::ConvertToBool(
        Yson::Lookup(Yson::Lookup($agg, $side), 'tov_minus_language_errors')
    ) ?? false;
};

$a = (
    SELECT
        $iid(input_meta)                    AS instruct_id,
        $le(agg_tov_markup, 'checkboxes_A') AS le_A,
        $le(agg_tov_markup, 'checkboxes_B') AS le_B
    FROM $input1
);

$b = (
    SELECT
        $iid(input_meta)                    AS instruct_id,
        $le(agg_tov_markup, 'checkboxes_A') AS le_A,
        $le(agg_tov_markup, 'checkboxes_B') AS le_B
    FROM $input2
);

$diff = (
    SELECT
        a.instruct_id      AS instruct_id,

        a.le_A             AS le_A_before,
        b.le_A             AS le_A_after,
        a.le_B             AS le_B_before,
        b.le_B             AS le_B_after,

        -- false -> true: ошибку в речи начали замечать
        (NOT a.le_A AND b.le_A)                          AS A_to_true,
        (NOT a.le_B AND b.le_B)                          AS B_to_true,
        -- true -> false: перестали
        (a.le_A AND NOT b.le_A)                          AS A_to_false,
        (a.le_B AND NOT b.le_B)                          AS B_to_false,

        -- главный флаг: хоть один из двух чекбоксов переключился на true
        ((NOT a.le_A AND b.le_A) OR (NOT a.le_B AND b.le_B)) AS any_to_true,
        -- любое изменение, в любую сторону
        (a.le_A != b.le_A OR a.le_B != b.le_B)              AS any_changed
    FROM $a AS a
    INNER JOIN $b AS b USING (instruct_id)
);

-- ВЫХОД 1: построчно. Оставить только изменившиеся — добавить WHERE any_changed.
INSERT INTO $output1 WITH TRUNCATE
SELECT *
FROM $diff;

-- ВЫХОД 2: сводка
INSERT INTO $output2 WITH TRUNCATE
SELECT
    COUNT(*)                     AS rows_joined,

    -- то, что просили: сколько строк, где хоть один чекбокс речевых ошибок стал true
    COUNT_IF(any_to_true)        AS rows_any_to_true,
    COUNT_IF(A_to_true)          AS rows_A_to_true,
    COUNT_IF(B_to_true)          AS rows_B_to_true,
    COUNT_IF(A_to_true AND B_to_true) AS rows_both_to_true,

    -- обратное направление и любое изменение — для контекста
    COUNT_IF(A_to_false OR B_to_false) AS rows_any_to_false,
    COUNT_IF(any_changed)              AS rows_any_changed,

    -- сколько всего было отмечено до и после
    COUNT_IF(le_A_before)        AS le_A_true_before,
    COUNT_IF(le_A_after)         AS le_A_true_after,
    COUNT_IF(le_B_before)        AS le_B_true_before,
    COUNT_IF(le_B_after)         AS le_B_true_after,

    1.0 * COUNT_IF(any_to_true) / COUNT(*) AS share_any_to_true
FROM $diff;
