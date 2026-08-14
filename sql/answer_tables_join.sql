DECLARE $input1 AS String;              -- корзина FM: input_final_messages, input_meta, input_render_data
DECLARE $output1 AS String;

PRAGMA yt.InferSchema = '1';
PRAGMA yt.UseNativeYtTypes;
PRAGMA Yson.AutoConvert;
PRAGMA StrictJoinKeyTypes;

$t0 = "//home/instruboba/kristisha/nirvana/output3_0833d2d7-eece-4f95-90aa-694ecff1920a";
$t1 = "//home/instruboba/kristisha/nirvana/output3_b7c39b0d-6aa0-4cd8-9e39-186c74ad6a66";

$basket = (
    SELECT
        COALESCE(Yson::ConvertToString(input_meta["instruct_id"]), "") AS instruct_id,
        input_final_messages,
        input_meta,
        input_render_data
    FROM $input1
);

-- Каждая таблица читается своим SELECT, номер проставляется литералом.
-- UNION ALL в YQL склеивает по именам колонок, поэтому имена одинаковые.
$answers = (
    SELECT
        0ul AS answer_index,
        COALESCE(instruct_id, "") AS instruct_id,
        COALESCE(answer, "") AS answer,
        COALESCE(answer_source, "") AS answer_source
    FROM $t0
    UNION ALL
    SELECT
        1ul AS answer_index,
        COALESCE(instruct_id, "") AS instruct_id,
        COALESCE(answer, "") AS answer,
        COALESCE(answer_source, "") AS answer_source
    FROM $t1
);

-- Длинная таблица ответов обеих моделей.
INSERT INTO $output1 WITH TRUNCATE
SELECT
    basket.input_final_messages AS input_final_messages,
    basket.input_meta AS input_meta,
    basket.input_render_data AS input_render_data,
    answers.answer AS answer,
    answers.answer_source AS answer_source,
    answers.answer_index AS answer_index,
    2ul AS answer_table_count
FROM $answers AS answers
JOIN $basket AS basket
    ON answers.instruct_id == basket.instruct_id;
