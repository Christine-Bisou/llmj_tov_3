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
DECLARE $output2 AS String;  -- сколько склеилось и как повёл бы себя второй вариант ключа

-- По чему склеивать: 'dialog' — весь диалог с ролями, 'user' — только реплики
-- пользователя. instruct ключом быть не может: местами он пустой, и такие
-- строки склеились бы друг с другом как попало.
$key_mode = 'dialog';

$empty_dialog = ListCreate(ParseType(@@Struct<'content':Utf8,'role':Utf8>@@));

$collapse = Re2::Replace(@@\s+@@);

$norm = ($s) -> {
    RETURN Unicode::ToLower(
        CAST(String::Strip(CAST($collapse(CAST($s AS Utf8), " ") AS String)) AS Utf8)
    ) ?? CAST('' AS Utf8);
};

$join_lines = ($lines) -> { RETURN $norm(String::JoinFromList($lines, "\n")) };

-- Весь диалог: роль в ключ входит, иначе один и тот же текст от пользователя
-- и от ассистента дал бы одинаковый ключ.
$dialog_key = ($dialog) -> {
    RETURN $join_lines(
        ListMap($dialog ?? $empty_dialog, ($m) -> {
            RETURN CAST($m.role AS String) || ": " || CAST($m.content AS String);
        })
    );
};

-- Только реплики пользователя: запасной вариант на случай, если контекст
-- ассистента в двух выгрузках окажется не побайтово одинаковым.
$user_key = ($dialog) -> {
    RETURN $join_lines(
        ListMap(
            ListExtract(
                ListFilter($dialog ?? $empty_dialog, ($m) -> { RETURN $m.role == 'user' }),
                'content'
            ),
            ($c) -> { RETURN CAST($c AS String) }
        )
    );
};

$pick = ($d, $u) -> { RETURN IF($key_mode == 'user', $u, $d) };

$left = (
    SELECT
        a.*,
        $dialog_key(a.dialog) AS key_dialog,
        $user_key(a.dialog) AS key_user,
        $pick($dialog_key(a.dialog), $user_key(a.dialog)) AS join_key
    FROM $input1 AS a
);

$right = (
    SELECT
        b.*,
        $dialog_key(b.dialog) AS key_dialog,
        $user_key(b.dialog) AS key_user,
        $pick($dialog_key(b.dialog), $user_key(b.dialog)) AS join_key
    FROM $input2 AS b
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
    FROM (SELECT * FROM $left WHERE join_key != '') AS a
    INNER JOIN (SELECT * FROM $right WHERE join_key != '') AS b ON a.join_key == b.join_key
);

INSERT INTO $output1 WITH TRUNCATE
SELECT j.* WITHOUT if exists j._other, j.join_key
FROM $joined AS j;

$left_rows = (SELECT COUNT(*) FROM $left);
$right_rows = (SELECT COUNT(*) FROM $right);

-- Сколько ключей нашли пару при каждом варианте: видно, теряет ли строгий
-- ключ по полному диалогу что-то против ключа по репликам пользователя.
$shared_dialog = (
    SELECT COUNT(*)
    FROM (SELECT DISTINCT key_dialog FROM $left WHERE key_dialog != '') AS l
    INNER JOIN (SELECT DISTINCT key_dialog FROM $right WHERE key_dialog != '') AS r
    USING (key_dialog)
);

$shared_user = (
    SELECT COUNT(*)
    FROM (SELECT DISTINCT key_user FROM $left WHERE key_user != '') AS l
    INNER JOIN (SELECT DISTINCT key_user FROM $right WHERE key_user != '') AS r
    USING (key_user)
);

-- Джоин по тексту не обязан быть один-к-одному: если один и тот же диалог
-- встречается в таблице дважды, пар получится больше, чем строк.
INSERT INTO $output2 WITH TRUNCATE
SELECT
    $key_mode                   AS key_mode,
    $left_rows                  AS left_rows,
    $right_rows                 AS right_rows,
    COUNT(*)                    AS joined_rows,
    COUNT(DISTINCT join_key)    AS joined_keys,
    $shared_dialog              AS shared_keys_dialog,
    $shared_user                AS shared_keys_user
FROM $joined;
