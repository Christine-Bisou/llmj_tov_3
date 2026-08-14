DECLARE $input1 AS String;              -- корзина FM: input_final_messages, input_meta, input_render_data
DECLARE $output1 AS String;
DECLARE $answer_tables_raw AS String;   -- пути таблиц с ответами, по одному в строке

PRAGMA yt.InferSchema = '1';
PRAGMA yt.UseNativeYtTypes;
PRAGMA Yson.AutoConvert;
PRAGMA StrictJoinKeyTypes;

$answer_tables = ListFilter(
    String::SplitToList($answer_tables_raw, "\n"),
    ($path) -> (String::Strip($path) != "")
);
$answer_tables = ListMap($answer_tables, ($path) -> (String::Strip($path)));
$answer_table_count = ListLength($answer_tables);

-- TablePath() отдаёт путь без ведущих слэшей, а в списке они обычно есть,
-- поэтому обе стороны приводим к одному виду.
$normalize = ($path) -> (IF(StartsWith($path, "//"), Substring($path, 2U), $path));

$path_to_index = ToDict(ListMap(
    ListEnumerate($answer_tables),
    ($item) -> (AsTuple($normalize($item.1), $item.0))
));

DISCARD SELECT Ensure(
    $answer_table_count,
    $answer_table_count > 0u,
    "answer_tables must contain at least one table"
);

-- Индекс таблицы берётся из пути, так что дубликат в списке сделал бы его неоднозначным.
DISCARD SELECT Ensure(
    $answer_table_count,
    ListLength(ListUniq($answer_tables)) == $answer_table_count,
    "answer_tables must not contain duplicate paths"
);

$basket = (
    SELECT
        COALESCE(Yson::ConvertToString(input_meta["instruct_id"]), "") AS instruct_id,
        input_final_messages,
        input_meta,
        input_render_data
    FROM $input1
);

-- PARTITION_LIST доступен только с языковой версии 2025.04, поэтому читаем
-- таблицы через EACH, а номер таблицы восстанавливаем по TablePath().
$answers = (
    SELECT
        Unwrap(
            $path_to_index[$normalize(TablePath())],
            "answer table path is missing in answer_tables"
        ) AS answer_index,
        COALESCE(instruct_id, "") AS instruct_id,
        COALESCE(answer, "") AS answer,
        COALESCE(answer_source, "") AS answer_source
    FROM EACH($answer_tables)
);

$basket_stats = (
    SELECT
        COUNT(*) AS row_count,
        COUNT(DISTINCT instruct_id) AS unique_count,
        COALESCE(SUM(IF(instruct_id == "", 1u, 0u)), 0u) AS empty_key_count
    FROM $basket
);

$per_table_stats = (
    SELECT
        answer_index,
        COUNT(*) AS row_count,
        COUNT(DISTINCT instruct_id) AS unique_id_count,
        COUNT(DISTINCT answer_source) AS source_count,
        MIN(answer_source) AS answer_source,
        COALESCE(SUM(IF(instruct_id == "", 1u, 0u)), 0u) AS empty_key_count,
        COALESCE(SUM(IF(answer == "", 1u, 0u)), 0u) AS empty_answer_count,
        COALESCE(SUM(IF(answer_source == "", 1u, 0u)), 0u) AS empty_source_count
    FROM $answers
    GROUP BY answer_index
);

$all_table_stats = (
    SELECT
        COUNT(*) AS table_count,
        COUNT(DISTINCT answer_source) AS unique_source_count,
        COALESCE(SUM(IF(
            row_count > 0u
                AND row_count == unique_id_count
                AND source_count == 1u
                AND empty_key_count == 0u
                AND empty_answer_count == 0u
                AND empty_source_count == 0u,
            0u,
            1u
        )), 0u) AS bad_table_count
    FROM $per_table_stats
);

$per_id_stats = (
    SELECT
        instruct_id,
        COUNT(DISTINCT answer_index) AS table_count
    FROM $answers
    GROUP BY instruct_id
);

$answer_set_stats = (
    SELECT
        COUNT(*) AS id_count,
        COALESCE(SUM(IF(table_count == $answer_table_count, 0u, 1u)), 0u) AS incomplete_id_count
    FROM $per_id_stats
);

$joined = (
    SELECT
        basket.input_final_messages AS input_final_messages,
        basket.input_meta AS input_meta,
        basket.input_render_data AS input_render_data,
        answers.answer AS answer,
        answers.answer_source AS answer_source,
        answers.answer_index AS answer_index,
        $answer_table_count AS answer_table_count
    FROM $answers AS answers
    JOIN $basket AS basket
        ON answers.instruct_id == basket.instruct_id
);

$joined_stats = (
    SELECT COUNT(*) AS row_count
    FROM $joined
);

$answer_stats = (
    SELECT COUNT(*) AS row_count
    FROM $answers
);

DISCARD SELECT Ensure(
    row_count,
    row_count > 0u
        AND row_count == unique_count
        AND empty_key_count == 0u,
    "FM basket must contain unique non-empty input_meta.instruct_id values"
)
FROM $basket_stats;

DISCARD SELECT Ensure(
    table_count,
    table_count == $answer_table_count
        AND unique_source_count == $answer_table_count
        AND bad_table_count == 0u,
    "Every answer table must be non-empty, unique by instruct_id, and have one unique non-empty answer_source"
)
FROM $all_table_stats;

DISCARD SELECT Ensure(
    id_count,
    id_count > 0u AND incomplete_id_count == 0u,
    "Answer tables must contain identical instruct_id sets"
)
FROM $answer_set_stats;

DISCARD SELECT Ensure(
    answers.id_count,
    answers.id_count == basket.row_count,
    "Answer tables must cover every instruct_id from the FM basket"
)
FROM $answer_set_stats AS answers
CROSS JOIN $basket_stats AS basket;

DISCARD SELECT Ensure(
    answers.row_count,
    answers.row_count == joined.row_count,
    "Every answer instruct_id must exist in the FM basket"
)
FROM $answer_stats AS answers
CROSS JOIN $joined_stats AS joined;

-- Длинная таблица ответов всех моделей в порядке answer_tables.
INSERT INTO $output1 WITH TRUNCATE
SELECT
    input_final_messages,
    input_meta,
    input_render_data,
    answer,
    answer_source,
    answer_index,
    answer_table_count
FROM $joined;
