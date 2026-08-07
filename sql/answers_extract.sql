PRAGMA Yson.AutoConvert;
PRAGMA yson.DisableStrict;
PRAGMA SimpleColumns;
PRAGMA AnsiOptionalAs;
PRAGMA yt.UseNativeYtTypes;
PRAGMA yt.InferSchema = '1';

DECLARE $input1 AS String;
DECLARE $input2 AS String;
DECLARE $output1 AS String;
DECLARE $output2 AS String;

-- Разворачиваем список answers: одна строка исходной таблицы -> по строке на каждый ответ.
--   model       = answers[i].answer_producer.name
--   dialog      = answers[i].final_messages (весь диалог целиком, как есть)
--   instruct_id = input_meta.instruct_id
--
-- answers и input_meta читаются как Yson-колонки (Yson::Lookup* работает и с Json).
-- Если в таблице они лежат нативными типами (List<Struct<...>>), см. вариант в конце файла.

$answers = (
    SELECT
        Yson::LookupString(input_meta, 'instruct_id') AS instruct_id,
        Yson::ConvertToList(answers)                  AS answers
    FROM $input1
);

INSERT INTO $output1 WITH TRUNCATE
SELECT
    instruct_id,
    Yson::LookupString(Yson::Lookup(answer, 'answer_producer'), 'name') AS model,
    -- Yson::Serialize сохраняет диалог структурой; для JSON-строки — Yson::SerializeJson
    Yson::Serialize(Yson::Lookup(answer, 'final_messages'))             AS dialog
FROM $answers
FLATTEN LIST BY answers AS answer
WHERE Yson::Contains(answer, 'answer_producer');

-- Вариант для нативно типизированной таблицы (answers: List<Struct<...>>):
--
-- INSERT INTO $output1 WITH TRUNCATE
-- SELECT
--     input_meta.instruct_id          AS instruct_id,
--     answer.answer_producer.name     AS model,
--     answer.final_messages           AS dialog
-- FROM $input1
-- FLATTEN LIST BY answers AS answer;
