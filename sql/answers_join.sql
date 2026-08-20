PRAGMA Yson.AutoConvert;
PRAGMA yson.DisableStrict;
PRAGMA SimpleColumns;
PRAGMA AnsiOptionalAs;
PRAGMA AnsiInForEmptyOrNullableItemsCollections;
PRAGMA yt.InferSchema = '1';

DECLARE $input1 AS String;   -- разметка: instruct_id, source_A, source_B, ...
DECLARE $input2 AS String;   -- прогон: input_meta.instruct_id, answers[].answer_producer.name
DECLARE $output1 AS String;  -- склейка: строка разметки + ответы, разложенные по A/B
DECLARE $output2 AS String;  -- диагностика склейки

-- Имена продюсеров сравниваем без учёта регистра и пробелов по краям.
$norm = ($s) -> {
    RETURN String::AsciiToUpper(String::Strip(CAST($s AS String) ?? ''));
};

-- Ключ пары: нормализованные имена, отсортированные по алфавиту.
-- Именно поэтому порядок продюсеров внутри answers роли не играет.
$key_from_list = ($names) -> {
    RETURN ListConcat(ListSort($names), ' + ');
};

$pair_key = ($x, $y) -> {
    RETURN $key_from_list(AsList($norm($x), $norm($y)));
};

-- имя продюсера из одного элемента answers
$node_name = ($answer) -> {
    RETURN CAST(Yson::ConvertToString(Yson::YPath($answer, '/answer_producer/name')) AS String);
};

-- Yson::From нужен, если колонка лежит нативным типом (struct/list).
-- Если input_meta / answers уже Yson или Json — Yson::From можно убрать.
$first = (
    SELECT
        CAST(a.instruct_id AS String)       AS instruct_id,
        $pair_key(a.source_A, a.source_B)   AS pair_key,
        $norm(a.source_A)                   AS source_a_key,
        $norm(a.source_B)                   AS source_b_key,
        a.* WITHOUT if exists a._other, a.instruct_id
    FROM $input1 AS a
);

$second = (
    SELECT
        CAST(Yson::ConvertToString(Yson::YPath(Yson::From(t.input_meta), '/instruct_id')) AS String) AS instruct_id,
        COALESCE(Yson::ConvertToList(Yson::From(t.answers)), ListCreate(Yson))                       AS answers_nodes,
        t.* WITHOUT if exists t._other, t.instruct_id
    FROM $input2 AS t
);

$second_named = (
    SELECT
        s.*,
        ListMap(answers_nodes, ($a) -> { RETURN $node_name($a) })        AS producers,
        ListMap(answers_nodes, ($a) -> { RETURN $norm($node_name($a)) }) AS producers_key
    FROM $second AS s
);

$second_keyed = (
    SELECT
        s.*,
        $key_from_list(producers_key) AS pair_key
    FROM $second_named AS s
    -- строки, где продюсеров не двое, парой не являются
    WHERE ListLength(producers_key) = 2
);

-- Собственно джойн: по instruct_id И по паре продюсеров.
-- Если в разметке для одного instruct_id несколько разных пар — они разойдутся
-- по разным строкам, а не склеятся друг с другом.
$joined = (
    SELECT
        f.*,
        s.answers_nodes AS answers_nodes,
        s.producers     AS producers,
        s.producers_key AS producers_key,
        s.input_meta    AS input_meta
        -- нужны ещё колонки из второй таблицы — дописывать сюда как s.<колонка>
    FROM $first AS f
    INNER JOIN $second_keyed AS s USING (instruct_id, pair_key)
);

-- Раскладываем answers по source_A / source_B: ищем позицию нужного продюсера.
$aligned = (
    SELECT
        j.*,
        ListIndexOf(producers_key, source_a_key) AS idx_a,
        ListIndexOf(producers_key, source_b_key) AS idx_b
    FROM $joined AS j
);

$picked = (
    SELECT
        t.* WITHOUT t.answers_nodes, t.producers_key, t.idx_a, t.idx_b,
        ListHead(ListSkip(answers_nodes, COALESCE(idx_a, 0ul))) AS answer_A_node,
        ListHead(ListSkip(answers_nodes, COALESCE(idx_b, 0ul))) AS answer_B_node,
        -- true, если в answers продюсеры лежат в обратном к разметке порядке
        idx_a != 0ul                                            AS swapped
    FROM $aligned AS t
    WHERE idx_a IS NOT NULL AND idx_b IS NOT NULL AND idx_a != idx_b
);

INSERT INTO $output1 WITH TRUNCATE
SELECT
    p.*,
    $node_name(answer_A_node)                        AS answer_A_producer,
    $node_name(answer_B_node)                        AS answer_B_producer,
    Yson::YPath(answer_A_node, '/final_messages')    AS answer_A_final_messages,
    Yson::YPath(answer_B_node, '/final_messages')    AS answer_B_final_messages,
    Yson::YPath(answer_A_node, '/meta')              AS answer_A_meta,
    Yson::YPath(answer_B_node, '/meta')              AS answer_B_meta,
    Yson::YPath(answer_A_node, '/render_data')       AS answer_A_render_data,
    Yson::YPath(answer_B_node, '/render_data')       AS answer_B_render_data
FROM $picked AS p;

-- Диагностика: сколько строк разметки нашло пару и почему остальные не нашли.
-- Джойн только по instruct_id, поэтому при нескольких прогонах на один
-- instruct_id строк здесь будет больше, чем в исходной разметке.
$diag = (
    SELECT
        f.instruct_id   AS instruct_id,
        f.pair_key      AS pair_first,
        s.pair_key      AS pair_second,
        CASE
            WHEN s.pair_key IS NULL       THEN 'нет instruct_id во второй таблице'
            WHEN f.pair_key = s.pair_key  THEN 'ок'
            ELSE 'instruct_id есть, пара продюсеров другая'
        END AS reason
    FROM $first AS f
    LEFT JOIN $second_keyed AS s USING (instruct_id)
);

INSERT INTO $output2 WITH TRUNCATE
SELECT
    reason,
    COUNT(*)            AS cnt,
    SOME(instruct_id)   AS sample_instruct_id,
    SOME(pair_first)    AS sample_pair_first,
    SOME(pair_second)   AS sample_pair_second
FROM $diag
GROUP BY reason
ORDER BY cnt DESC;
