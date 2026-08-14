DECLARE $input1 AS String;   -- первая: input_final_messages, input_meta, input_render_data
DECLARE $input2 AS String;   -- вторая: instruct_id, approved_by, last_markup_dt, winner_source
DECLARE $output1 AS String;
DECLARE $output2 AS String;

PRAGMA yt.InferSchema = '1';
PRAGMA yt.UseNativeYtTypes;
PRAGMA Yson.AutoConvert;
PRAGMA yson.DisableStrict;
PRAGMA yt.DefaultMaxJobFails = "1";

-- Ключ джоина лежит внутри input_meta, а YQL джоинит только по колонкам,
-- не по выражениям. Поэтому сначала вытаскиваем его в отдельную колонку.
-- Если input_meta не Yson, а обычная структура, замените Yson::LookupString
-- на CAST(a.input_meta.instruct_id AS String).
$left = (
    SELECT
        CAST(Yson::LookupString(a.input_meta, 'instruct_id') AS String) AS instruct_id,
        a.input_final_messages                                          AS input_final_messages,
        a.input_meta                                                    AS input_meta,
        a.input_render_data                                             AS input_render_data
    FROM $input1 AS a
);

$right = (
    SELECT
        CAST(b.instruct_id AS String) AS instruct_id,
        b.approved_by                 AS approved_by,
        b.last_markup_dt              AS last_markup_dt,
        b.winner_source               AS winner_source
    FROM $input2 AS b
);

-- INNER: остаются только пары, у которых есть разметка во второй таблице.
-- Нужны все строки первой таблицы — поменяйте INNER JOIN на LEFT JOIN.
INSERT INTO $output1 WITH TRUNCATE
SELECT
    l.instruct_id           AS instruct_id,
    l.input_final_messages  AS input_final_messages,
    l.input_meta            AS input_meta,
    l.input_render_data     AS input_render_data,
    r.approved_by           AS approved_by,
    r.last_markup_dt        AS last_markup_dt,
    r.winner_source         AS winner_source
FROM $left AS l
INNER JOIN $right AS r
    ON l.instruct_id == r.instruct_id
WHERE l.instruct_id IS NOT NULL;
