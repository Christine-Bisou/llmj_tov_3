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

$basket = (
    SELECT
        COALESCE(Yson::ConvertToString(input_meta["instruct_id"]), "") AS instruct_id,
        input_final_messages,
        input_meta,
        input_render_data
    FROM $input1
);

-- PARTITION_LIST доступен только с языковой версии 2025.04, а TablePath()
-- зависит от формы пути, поэтому читаем каждую таблицу отдельным чтением
-- и берём номер из позиции пути в списке.
DEFINE SUBQUERY $read_answers($path) AS
    SELECT
        Unwrap(ListIndexOf($answer_tables, $path)) AS answer_index,
        COALESCE(instruct_id, "") AS instruct_id,
        COALESCE(answer, "") AS answer,
        COALESCE(answer_source, "") AS answer_source
    FROM $path;
END DEFINE;

$answers = SubqueryUnionAllFor($answer_tables, $read_answers);

-- Длинная таблица ответов всех моделей в порядке answer_tables.
INSERT INTO $output1 WITH TRUNCATE
SELECT
    basket.input_final_messages AS input_final_messages,
    basket.input_meta AS input_meta,
    basket.input_render_data AS input_render_data,
    answers.answer AS answer,
    answers.answer_source AS answer_source,
    answers.answer_index AS answer_index,
    $answer_table_count AS answer_table_count
FROM $answers() AS answers
JOIN $basket AS basket
    ON answers.instruct_id == basket.instruct_id;
