DECLARE $input1 AS String;   -- исходная разметка
DECLARE $input2 AS String;   -- перепроверенная разметка, ей отдаём приоритет
DECLARE $output1 AS String;
DECLARE $output2 AS String;

PRAGMA yt.UseNativeYtTypes;

-- Ключ пары моделей, нечувствительный к порядку ответов: в перепроверке
-- ответы могли уехать местами, а winner_source хранит имя источника,
-- а не model_1/model_2, поэтому разворот пары ничего не ломает.
$pair_key = ($s1, $s2) -> {
    $a = COALESCE(CAST($s1 AS String), '');
    $b = COALESCE(CAST($s2 AS String), '');
    RETURN IF($a <= $b, $a || '\t' || $b, $b || '\t' || $a);
};

$src = (
    SELECT
        s.*,
        $pair_key(s.answer_source_1, s.answer_source_2) AS models_key
    FROM $input1 AS s
);

$upd = (
    SELECT
        u.pool_id          AS pool_id,
        u.real_instruct_id AS real_instruct_id,
        $pair_key(u.answer_source_1, u.answer_source_2) AS models_key,

        u.approved_by      AS approved_by,
        u.comment          AS comment,
        u.last_markup_dt   AS last_markup_dt,
        u.winner_source    AS winner_source
    FROM $input2 AS u
);

INSERT INTO $output1
SELECT
    src.answer_1 AS answer_1,
    src.answer_2 AS answer_2,
    src.answer_source_1 AS answer_source_1,
    src.answer_source_2 AS answer_source_2,

    IF(upd.models_key IS NOT NULL, upd.approved_by, src.approved_by) AS approved_by,
    IF(upd.models_key IS NOT NULL, upd.comment, src.comment) AS comment,

    src.dialog AS dialog,
    src.instruct_id AS instruct_id,

    IF(upd.models_key IS NOT NULL, upd.last_markup_dt, src.last_markup_dt) AS last_markup_dt,

    src.pool_id AS pool_id,
    src.pool_type AS pool_type,
    src.real_instruct_id AS real_instruct_id,

    IF(upd.models_key IS NOT NULL, upd.winner_source, src.winner_source) AS winner_source,

    src.original_markup_dt AS original_markup_dt
FROM $src AS src
LEFT JOIN $upd AS upd
    ON src.pool_id = upd.pool_id
    AND src.real_instruct_id = upd.real_instruct_id
    AND src.models_key = upd.models_key
;
