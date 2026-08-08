PRAGMA SimpleColumns;
PRAGMA yt.InferSchema = '1';

-- Вход для рендера семи ответов.
-- $input1 — ответы: answer_1..answer_7, model_1..model_7, dialog_2.
-- $input2 — ссылки: instruct_id + html_url.
-- Джойн по instruct_id, пересечение: что есть в обеих таблицах, то и остаётся.

DECLARE $input1 AS String;
DECLARE $input2 AS String;
DECLARE $output1 AS String;

INSERT INTO $output1 WITH TRUNCATE
SELECT
    a.instruct_id AS instruct_id,
    a.dialog_2 AS dialog,
    a.answer_1 AS answer_1,
    a.answer_2 AS answer_2,
    a.answer_3 AS answer_3,
    a.answer_4 AS answer_4,
    a.answer_5 AS answer_5,
    a.answer_6 AS answer_6,
    a.answer_7 AS answer_7,
    a.model_1 AS model_1,
    a.model_2 AS model_2,
    a.model_3 AS model_3,
    a.model_4 AS model_4,
    a.model_5 AS model_5,
    a.model_6 AS model_6,
    a.model_7 AS model_7,
    u.html_url AS html_url
FROM $input1 AS a
INNER JOIN $input2 AS u
USING (instruct_id);
