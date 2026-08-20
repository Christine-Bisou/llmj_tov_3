PRAGMA Yson.AutoConvert;
PRAGMA yson.DisableStrict;
PRAGMA SimpleColumns;
PRAGMA AnsiOptionalAs;
PRAGMA AnsiInForEmptyOrNullableItemsCollections;
PRAGMA yt.InferSchema = '1';

DECLARE $input1 AS String;   -- разметка: instruct_id, source_A, source_B, ...
DECLARE $input2 AS String;   -- прогон: input_meta.instruct_id, answers[].answer_producer.name
DECLARE $output1 AS String;  -- склейка: строка разметки + колонки прогона

-- Имена продюсеров сравниваем без учёта регистра и пробелов по краям.
$norm = ($s) -> {
    RETURN String::AsciiToUpper(String::Strip(CAST($s AS String) ?? ''));
};

-- Ключ пары: нормализованные имена, отсортированные по алфавиту.
-- Именно поэтому порядок продюсеров внутри answers роли не играет.
$pair_key = ($x, $y) -> {
    RETURN ListConcat(ListSort(AsList($norm($x), $norm($y))), ' + ');
};

-- Победитель записан то именем источника, то позицией — приводим к имени.
-- tie / both_bad / skip / пусто считаем ничьёй, как в error_breakdown.sql.
$winner_name = ($w, $name_1, $name_2) -> {
    $v = $norm($w);
    RETURN CASE
        WHEN $v IN ('DRAW', 'TIE', 'BOTH_BAD', 'SKIP', '') THEN 'DRAW'
        WHEN $v IN ('MODEL_1', 'SOURCE_A', 'A')            THEN $norm($name_1)
        WHEN $v IN ('MODEL_2', 'SOURCE_B', 'B')            THEN $norm($name_2)
        ELSE $v
    END;
};

-- Yson::From нужен, если колонка лежит нативным типом (struct/list).
-- Если answers / input_meta уже Yson или Json — Yson::From можно убрать.
-- К элементам answers обращаемся по индексу: '/0/...', '/1/...'.
$producer_at = ($answers, $i) -> {
    RETURN CAST(Yson::ConvertToString(
        Yson::YPath(Yson::From($answers), '/' || CAST($i AS String) || '/answer_producer/name')
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
        CAST(Yson::ConvertToString(Yson::YPath(Yson::From(t.out_tov), '/winner')) AS String) AS tov_winner_raw,
        t.answers               AS answers,
        t.input_final_messages  AS input_final_messages,
        t.input_meta            AS input_meta,
        t.input_render_data     AS input_render_data,
        t.out_tov               AS out_tov,
        t.raw_tov               AS raw_tov
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
        s.producer_0            AS producer_0,
        s.producer_1            AS producer_1,
        s.tov_winner_raw        AS tov_winner_raw,
        s.answers               AS answers,
        s.input_final_messages  AS input_final_messages,
        s.input_meta            AS input_meta,
        s.input_render_data     AS input_render_data,
        s.out_tov               AS out_tov,
        s.raw_tov               AS raw_tov
    FROM $first AS f
    INNER JOIN $second_keyed AS s USING (instruct_id, pair_key)
);

-- Вердикты обеих таблиц в одном пространстве значений — именах продюсеров.
$verdicts = (
    SELECT
        j.*,
        -- true, если в answers продюсеры лежат в обратном к разметке порядке:
        -- answers[0] — это source_B, а answers[1] — source_A
        $norm(j.producer_0) != j.source_a_key                       AS swapped,
        $winner_name(j.source_winner, j.source_A, j.source_B)       AS winner_markup,
        $winner_name(j.tov_winner_raw, j.producer_0, j.producer_1)  AS winner_tov
    FROM $joined AS j
);

-- Оставляем только расхождения разметки и джаджа.
-- WITHOUT должен идти последним в списке колонок, иначе всё, что после него,
-- парсер считает продолжением списка исключаемых колонок.
INSERT INTO $output1 WITH TRUNCATE
SELECT
    v.* WITHOUT v.pair_key, v.source_a_key, v.producer_0, v.producer_1, v.tov_winner_raw
FROM $verdicts AS v
WHERE v.winner_markup != v.winner_tov;
