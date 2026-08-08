PRAGMA Yson.AutoConvert;
PRAGMA yson.DisableStrict;
PRAGMA SimpleColumns;
PRAGMA AnsiOptionalAs;
PRAGMA yt.UseNativeYtTypes;
PRAGMA AnsiInForEmptyOrNullableItemsCollections;
PRAGMA yt.InferSchema = '1';

-- Обе таблицы — выход extract_query_answers.sql, по одному прогону в каждой.
-- Левая становится model_1/answer_1, правая — model_2/answer_2.
DECLARE $input1 AS String;
DECLARE $input2 AS String;
DECLARE $output1 AS String;  -- пара ответов на один запрос
DECLARE $output2 AS String;  -- сколько строк склеилось

$empty_dialog = ListCreate(ParseType(@@Struct<'content':Utf8,'role':Utf8>@@));

$collapse = Re2::Replace(@@\s+@@);

$norm = ($s) -> {
    RETURN Unicode::ToLower(
        CAST(String::Strip(CAST($collapse(CAST($s AS Utf8), " ") AS String)) AS Utf8)
    ) ?? CAST('' AS Utf8);
};

-- Ключ — все реплики пользователя из диалога, а не instruct: instruct местами
-- пустой, и такие строки склеились бы друг с другом как попало. Реплики
-- ассистента в ключ не берём — они у разных моделей разные.
$key = ($dialog) -> {
    RETURN $norm(
        String::JoinFromList(
            ListMap(
                ListExtract(
                    ListFilter($dialog ?? $empty_dialog, ($m) -> { RETURN $m.role == 'user' }),
                    'content'
                ),
                ($c) -> { RETURN CAST($c AS String) }
            ),
            "\n"
        )
    );
};

$left = (
    SELECT a.*, $key(a.dialog) AS join_key
    FROM $input1 AS a
    WHERE $key(a.dialog) != ''
);

$right = (
    SELECT b.*, $key(b.dialog) AS join_key
    FROM $input2 AS b
    WHERE $key(b.dialog) != ''
);

$joined = (
    SELECT
        -- instruct и dialog одинаковые с обеих сторон, оставляем один
        a.instruct              AS instruct,
        a.dialog                AS dialog,

        a.vendor                AS model_1,
        a.answer                AS answer_1,
        b.vendor                AS model_2,
        b.answer                AS answer_2,

        a.row_id                AS row_id_1,
        b.row_id                AS row_id_2,
        a.account               AS account_1,
        b.account               AS account_2,
        a.s3_page_source        AS s3_page_source_1,
        b.s3_page_source        AS s3_page_source_2,
        a.answer_time           AS answer_time_1,
        b.answer_time           AS answer_time_2,

        -- параметры прогона общие для пары
        a.locale_code           AS locale_code,
        a.model_type            AS model_type,
        a.search                AS search,
        a.thinking_enabled      AS thinking_enabled,

        a.join_key              AS join_key
    FROM $left AS a
    INNER JOIN $right AS b ON a.join_key == b.join_key
);

INSERT INTO $output1 WITH TRUNCATE
SELECT j.* WITHOUT if exists j._other, j.join_key
FROM $joined AS j;

$left_rows = (SELECT COUNT(*) FROM $left);
$right_rows = (SELECT COUNT(*) FROM $right);

-- Джоин по тексту не обязан быть один-к-одному: если один и тот же запрос
-- встречается в таблице дважды, пар получится больше, чем строк.
INSERT INTO $output2 WITH TRUNCATE
SELECT
    $left_rows                  AS left_rows,
    $right_rows                 AS right_rows,
    COUNT(*)                    AS joined_rows,
    COUNT(DISTINCT join_key)    AS joined_keys
FROM $joined;
