PRAGMA Yson.AutoConvert;
PRAGMA yson.DisableStrict;
PRAGMA SimpleColumns;
PRAGMA AnsiOptionalAs;
PRAGMA AnsiInForEmptyOrNullableItemsCollections;
PRAGMA yt.InferSchema = '1';

DECLARE $input1 AS String;   -- прогон модели: input_meta.instruct_id + out_tov.out_tov (model_1 / model_2 / draw)
DECLARE $input2 AS String;   -- разметка: input_meta.instruct_id + tov_memory (true / false)
DECLARE $output1 AS String;  -- построчная склейка с баллами
DECLARE $output2 AS String;  -- две метрики: soft и strict

-- ------------------------------------------------------------------
-- Достаём instruct_id из input_meta. ConvertToString + AutoConvert,
-- чтобы пережить и строковый, и числовой id.
-- ------------------------------------------------------------------
$iid = ($m) -> {
    RETURN Yson::ConvertToString(Yson::Lookup($m, 'instruct_id'));
};

-- вердикт модели лежит вложенным полем out_tov внутри колонки out_tov
$verdict = ($node) -> {
    RETURN Yson::ConvertToString(Yson::Lookup($node, 'out_tov'));
};

-- tie / both_bad / skip / пусто / NULL — всё это ничья
$norm = ($v) -> {
    RETURN CASE
        WHEN $v IS NULL                              THEN 'draw'
        WHEN $v IN ('tie', 'both_bad', 'skip', '')   THEN 'draw'
        ELSE $v
    END;
};

-- tov_memory может приехать как Bool, как строка или как 0/1
$flag = ($v) -> {
    RETURN CASE
        WHEN $v IS NULL                          THEN false
        WHEN String::AsciiToLower($v) IN ('true', '1', 'yes', 't') THEN true
        ELSE false
    END;
};

-- ------------------------------------------------------------------
-- Метрики.
--   tov_memory = true  -> правильный ответ model_2
--   tov_memory = false -> правильный ответ ничья
--
-- soft   : попадание = 1, расхождение через ничью = 0.5, обратный выбор = 0
-- strict : попадание = 1, всё остальное = 0
-- ------------------------------------------------------------------
-- Таблица баллов:
--   tov_memory  gold      pred      soft   strict
--   true        model_2   model_2   1.0    1.0
--   true        model_2   draw      0.5    0.0
--   true        model_2   model_1   0.0    0.0
--   false       draw      draw      1.0    1.0
--   false       draw      model_1   0.5    0.0
--   false       draw      model_2   0.5    0.0
-- ------------------------------------------------------------------
$soft = ($pred, $gold) -> {
    RETURN CASE
        WHEN $pred = $gold                          THEN 1.0
        WHEN $pred = 'draw' OR $gold = 'draw'       THEN 0.5
        ELSE 0.0
    END;
};

$strict = ($pred, $gold) -> {
    RETURN IF($pred = $gold, 1.0, 0.0);
};

$left = (
    SELECT
        $iid(a.input_meta)                      AS instruct_id,
        $norm($verdict(a.out_tov))              AS pred,
        a.* WITHOUT if exists a.instruct_id, a.pred
    FROM $input1 AS a
);

$right = (
    SELECT
        $iid(b.input_meta)                      AS instruct_id,
        $flag(CAST(b.tov_memory AS String))     AS tov_memory
    FROM $input2 AS b
);

$joined = (
    SELECT
        l.instruct_id                           AS instruct_id,
        l.pred                                  AS pred,
        COALESCE(r.tov_memory, false)           AS tov_memory,
        IF(r.instruct_id IS NULL, false, true)  AS matched,
        l.* WITHOUT l.instruct_id, l.pred
    FROM $left AS l
    LEFT JOIN $right AS r ON l.instruct_id = r.instruct_id
);

$scored = (
    SELECT
        j.*,
        IF(j.tov_memory, 'model_2', 'draw')                      AS gold,
        $soft(j.pred,   IF(j.tov_memory, 'model_2', 'draw'))     AS soft_score,
        $strict(j.pred, IF(j.tov_memory, 'model_2', 'draw'))     AS strict_score,
        j.matched AND j.tov_memory                               AS seg_problem,
        j.matched AND NOT j.tov_memory                           AS seg_no_problem
    FROM $joined AS j
);

INSERT INTO $output1 WITH TRUNCATE
SELECT * FROM $scored
ORDER BY instruct_id;

-- ------------------------------------------------------------------
-- Итог: одна строка, каждый блок — словарь (json).
--
--   no_tov_memory_problem           распределение ответов на tov_memory = false
--   tov_memory_problem              распределение ответов на tov_memory = true
--   no_tov_memory_problem_quantity  качество на false: ничья = 1, любой
--                                   победитель = 0.5 (soft) и 0 (strict)
--   tov_memory_problem_quantity     качество на true: model_2 = 1,
--                                   draw = 0.5 (soft) и 0 (strict), model_1 = 0
-- ------------------------------------------------------------------
INSERT INTO $output2 WITH TRUNCATE
SELECT
    Yson::SerializeJson(Yson::From(AsStruct(
        COUNT_IF(seg_no_problem AND pred = 'model_1')   AS model_1,
        COUNT_IF(seg_no_problem AND pred = 'draw')      AS draw,
        COUNT_IF(seg_no_problem AND pred = 'model_2')   AS model_2,
        COUNT_IF(seg_no_problem)                        AS total
    )))                                                 AS no_tov_memory_problem,

    Yson::SerializeJson(Yson::From(AsStruct(
        COUNT_IF(seg_problem AND pred = 'model_1')      AS model_1,
        COUNT_IF(seg_problem AND pred = 'draw')         AS draw,
        COUNT_IF(seg_problem AND pred = 'model_2')      AS model_2,
        COUNT_IF(seg_problem)                           AS total
    )))                                                 AS tov_memory_problem,

    Yson::SerializeJson(Yson::From(AsStruct(
        AVG(IF(seg_no_problem, soft_score))             AS soft,
        AVG(IF(seg_no_problem, strict_score))           AS strict,
        COUNT_IF(seg_no_problem)                        AS cnt
    )))                                                 AS no_tov_memory_problem_quantity,

    Yson::SerializeJson(Yson::From(AsStruct(
        AVG(IF(seg_problem, soft_score))                AS soft,
        AVG(IF(seg_problem, strict_score))              AS strict,
        COUNT_IF(seg_problem)                           AS cnt
    )))                                                 AS tov_memory_problem_quantity,

    COUNT_IF(NOT matched)                               AS not_matched
FROM $scored;
