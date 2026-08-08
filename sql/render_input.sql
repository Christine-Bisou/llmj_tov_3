PRAGMA SimpleColumns;
PRAGMA yt.InferSchema = '1';
PRAGMA AnsiInForEmptyOrNullableItemsCollections;

-- Вход для рендера семи ответов.
-- $input1 — таблица с ответами: answer_1..answer_7, model_1..model_7, dialog_2.
-- $input2 — таблица со ссылками: instruct + html_url.
-- Джойн по instruct, пересечение: остаются только те инстракты, что есть
-- в обеих таблицах, поэтому маленький $input2 обрезает результат.
-- $output1 — строки, готовые к рендеру: все 7 ответов заполнены и есть html_url.
-- $output2 — что отвалилось и почему (чтобы потери были видны).

DECLARE $input1 AS String;
DECLARE $input2 AS String;
DECLARE $output1 AS String;
DECLARE $output2 AS String;

-- Заполнено = не NULL и не пробелы.
$filled = ($x) -> ( COALESCE(String::Strip(CAST($x AS String)) != '', false) );

$prepared = (
    SELECT
        instruct,
        dialog_2 AS dialog,
        answer_1, answer_2, answer_3, answer_4, answer_5, answer_6, answer_7,
        model_1,  model_2,  model_3,  model_4,  model_5,  model_6,  model_7,
        $filled(answer_1) AND $filled(answer_2) AND $filled(answer_3)
            AND $filled(answer_4) AND $filled(answer_5) AND $filled(answer_6)
            AND $filled(answer_7) AS all_answers
    FROM $input1
);

-- По одной ссылке на инстракт.
$urls = (
    SELECT
        instruct,
        SOME(html_url) AS html_url
    FROM $input2
    WHERE html_url IS NOT NULL
    GROUP BY instruct
);

-- Пересечение по instruct: строк не больше, чем в $input2.
$matched = (
    SELECT
        p.*,
        u.html_url AS html_url
    FROM $prepared AS p
    INNER JOIN $urls AS u USING (instruct)
);

INSERT INTO $output1 WITH TRUNCATE
SELECT
    instruct,
    dialog,
    answer_1, answer_2, answer_3, answer_4, answer_5, answer_6, answer_7,
    model_1,  model_2,  model_3,  model_4,  model_5,  model_6,  model_7,
    html_url
FROM $matched
WHERE all_answers;

INSERT INTO $output2 WITH TRUNCATE
SELECT
    instruct,
    'not_all_answers' AS reason
FROM $matched
WHERE NOT all_answers

UNION ALL

SELECT
    instruct,
    'no_html_url' AS reason
FROM $prepared AS p
LEFT ONLY JOIN $urls AS u USING (instruct);
