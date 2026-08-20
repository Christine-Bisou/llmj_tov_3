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
$pair_key = ($x, $y) -> {
    RETURN ListConcat(ListSort(AsList($norm($x), $norm($y))), ' + ');
};

-- Yson::From нужен, если колонка лежит нативным типом (struct/list).
-- Если answers / input_meta уже Yson или Json — Yson::From можно убрать.
-- Обращаемся к элементам списка по индексу: '/0/...', '/1/...'.
$answer_at = ($answers, $i) -> {
    RETURN Yson::YPath(Yson::From($answers), '/' || CAST($i AS String));
};

$producer_at = ($answers, $i) -> {
    RETURN CAST(Yson::ConvertToString(
        Yson::YPath($answer_at($answers, $i), '/answer_producer/name')
    ) AS String);
};

$first = (
    SELECT
        CAST(a.instruct_id AS String)       AS instruct_id,
        $pair_key(a.source_A, a.source_B)   AS pair_key,
        $norm(a.source_A)                   AS source_a_key,
        a.* WITHOUT if exists a._other, a.instruct_id
    FROM $input1 AS a
);

$second = (
    SELECT
        CAST(Yson::ConvertToString(Yson::YPath(Yson::From(t.input_meta), '/instruct_id')) AS String) AS instruct_id,
        $producer_at(t.answers, 0) AS producer_0,
        $producer_at(t.answers, 1) AS producer_1,
        t.* WITHOUT if exists t._other, t.instruct_id
    FROM $input2 AS t
);

$second_keyed = (
    SELECT
        s.*,
        $pair_key(producer_0, producer_1) AS pair_key
    FROM $second AS s
    -- строки, где продюсеров не двое, парой не являются
    WHERE producer_0 IS NOT NULL AND producer_1 IS NOT NULL
);

-- Собственно джойн: по instruct_id И по паре продюсеров.
-- Если в разметке для одного instruct_id несколько разных пар — они разойдутся
-- по разным строкам, а не склеятся друг с другом.
$joined = (
    SELECT
        f.*,
        s.answers    AS answers,
        s.producer_0 AS producer_0,
        s.producer_1 AS producer_1,
        s.input_meta AS input_meta
        -- нужны ещё колонки из второй таблицы — дописывать сюда как s.<колонка>
    FROM $first AS f
    INNER JOIN $second_keyed AS s USING (instruct_id, pair_key)
);

-- Раскладываем answers по source_A / source_B. Пара уже совпала по ключу,
-- поэтому достаточно понять, на каком месте лежит source_A.
$aligned = (
    SELECT
        j.*,
        IF($norm(producer_0) = source_a_key, 0, 1) AS idx_a,
        IF($norm(producer_0) = source_a_key, 1, 0) AS idx_b
    FROM $joined AS j
);

-- WITHOUT должен идти последним в списке колонок, иначе всё, что после него,
-- парсер считает продолжением списка исключаемых колонок.
INSERT INTO $output1 WITH TRUNCATE
SELECT
    Yson::Serialize($answer_at(t.answers, t.idx_a)) AS answer_A,
    Yson::Serialize($answer_at(t.answers, t.idx_b)) AS answer_B,
    $producer_at(t.answers, t.idx_a)                AS answer_A_producer,
    $producer_at(t.answers, t.idx_b)                AS answer_B_producer,

    Yson::Serialize(Yson::YPath($answer_at(t.answers, t.idx_a), '/final_messages')) AS answer_A_final_messages,
    Yson::Serialize(Yson::YPath($answer_at(t.answers, t.idx_b), '/final_messages')) AS answer_B_final_messages,
    Yson::Serialize(Yson::YPath($answer_at(t.answers, t.idx_a), '/meta'))           AS answer_A_meta,
    Yson::Serialize(Yson::YPath($answer_at(t.answers, t.idx_b), '/meta'))           AS answer_B_meta,

    -- true, если в answers продюсеры лежат в обратном к разметке порядке
    t.idx_a != 0                                    AS swapped,

    t.* WITHOUT t.idx_a, t.idx_b
FROM $aligned AS t;

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
