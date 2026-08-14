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

-- Номер ответа считаем внутри instruct_id: он не зависит ни от того, сколькими
-- таблицами отдали прогон, ни от того, что лежит в answer_source.
$numbered = (
    SELECT
        instruct_id,
        answer,
        answer_source,
        ROW_NUMBER() OVER w - 1ul AS answer_index,
        COUNT(*) OVER p AS answer_table_count
    FROM $answers()
    WINDOW
        w AS (PARTITION BY instruct_id ORDER BY answer_source),
        p AS (PARTITION BY instruct_id)
);

-- Длинная таблица: по строке на каждый найденный ответ для instruct_id.
INSERT INTO $output1 WITH TRUNCATE
SELECT
    basket.input_final_messages AS input_final_messages,
    basket.input_meta AS input_meta,
    basket.input_render_data AS input_render_data,
    answers.answer AS answer,
    answers.answer_source AS answer_source,
    answers.answer_index AS answer_index,
    answers.answer_table_count AS answer_table_count
FROM $numbered AS answers
JOIN $basket AS basket
    ON answers.instruct_id == basket.instruct_id;
