DECLARE $input1 AS String;              -- корзина FM: input_final_messages, input_meta, input_render_data
DECLARE $output1 AS String;
DECLARE $answer_tables_raw AS String;   -- пути таблиц с ответами, по одному в строке

PRAGMA yt.InferSchema = '1';
PRAGMA yt.UseNativeYtTypes;
PRAGMA Yson.AutoConvert;
PRAGMA StrictJoinKeyTypes;

$answer_tables = ListFilter(
    ListMap(
        String::SplitToList(String::ReplaceAll($answer_tables_raw, "\r", ""), "\n"),
        ($path) -> (String::Strip($path))
    ),
    ($path) -> ($path != "")
);

$basket = (
    SELECT
        COALESCE(Yson::ConvertToString(input_meta["instruct_id"]), "") AS instruct_id,
        input_final_messages,
        input_meta,
        input_render_data
    FROM $input1
);

-- PARTITION_LIST есть только с версии 2025.04, а TablePath() зависит от формы
-- пути, поэтому читаем каждую таблицу отдельным чтением и склеиваем.
DEFINE SUBQUERY $read_answers($path) AS
    SELECT
        COALESCE(instruct_id, "") AS instruct_id,
        COALESCE(answer, "") AS answer,
        COALESCE(answer_source, "") AS answer_source
    FROM $path;
END DEFINE;

$answers = SubqueryUnionAllFor($answer_tables, $read_answers);

-- Номер ответа — позиция модели в отсортированном списке answer_source.
-- Один прогон может лежать в нескольких таблицах, поэтому по таблицам не нумеруем.
$sources = (SELECT ListSort(AGGREGATE_LIST_DISTINCT(answer_source)) FROM $answers());

-- Длинная таблица: по строке на каждую модель для каждого instruct_id.
INSERT INTO $output1 WITH TRUNCATE
SELECT
    basket.input_final_messages AS input_final_messages,
    basket.input_meta AS input_meta,
    basket.input_render_data AS input_render_data,
    answers.answer AS answer,
    answers.answer_source AS answer_source,
    COALESCE(ListIndexOf($sources, answers.answer_source), 0ul) AS answer_index,
    CAST(ListLength($sources) AS Uint64) AS answer_table_count
FROM $answers() AS answers
JOIN $basket AS basket
    ON answers.instruct_id == basket.instruct_id;
