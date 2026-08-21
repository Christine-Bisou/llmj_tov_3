DECLARE $input1 AS String;
DECLARE $input2 AS String;
DECLARE $output1 AS String;
DECLARE $output2 AS String;

PRAGMA Yson.AutoConvert;
PRAGMA yson.DisableStrict;
PRAGMA SimpleColumns;
PRAGMA yt.InferSchema = '1';

INSERT INTO $output1
SELECT
    a.*,
    CASE CAST(b.`есть проблема в ToV?` AS String)
        WHEN "Да"  THEN true
        WHEN "Нет" THEN false
        ELSE NULL
    END          AS tov_memory,
    b.user_facts AS user_facts,
    b.bucket     AS bucket
FROM $input1 AS a
LEFT JOIN $input2 AS b
ON Yson::ConvertToString(a.input_meta["instruct_id"]) = CAST(b.instruct_id AS String);
