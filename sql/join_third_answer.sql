PRAGMA Yson.AutoConvert;
PRAGMA yson.DisableStrict;
PRAGMA SimpleColumns;
PRAGMA AnsiOptionalAs;
PRAGMA yt.UseNativeYtTypes;
PRAGMA AnsiInForEmptyOrNullableItemsCollections;
PRAGMA yt.InferSchema = '1';

DECLARE $input1 AS String;   -- готовая пара: dialog, model_1/2, answer_1/2, ...
DECLARE $input2 AS String;   -- третий прогон, выход extract_query_answers.sql
DECLARE $output1 AS String;  -- пара + третий ответ
DECLARE $output2 AS String;  -- сколько пар нашло третий ответ

-- Ключ тот же, что и при склейке пары: 'dialog' — весь диалог с ролями,
-- 'user' — только реплики пользователя.
$key_mode = 'dialog';

$empty_dialog = ListCreate(ParseType(@@Struct<'content':Utf8,'role':Utf8>@@));

$collapse = Re2::Replace(@@\s+@@);

$norm = ($s) -> {
    RETURN Unicode::ToLower(
        CAST(String::Strip(CAST($collapse(CAST($s AS Utf8), " ") AS String)) AS Utf8)
    ) ?? CAST('' AS Utf8);
};

$join_lines = ($lines) -> { RETURN $norm(String::JoinFromList($lines, "\n")) };

$dialog_key = ($dialog) -> {
    RETURN $join_lines(
        ListMap($dialog ?? $empty_dialog, ($m) -> {
            RETURN CAST($m.role AS String) || ": " || CAST($m.content AS String);
        })
    );
};

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

$pairs = (
    SELECT
        p.*,
        $dialog_key(p.dialog) AS key_dialog,
        $user_key(p.dialog) AS key_user,
        $pick($dialog_key(p.dialog), $user_key(p.dialog)) AS join_key
    FROM $input1 AS p
);

$third = (
    SELECT
        c.*,
        $dialog_key(c.dialog) AS key_dialog,
        $user_key(c.dialog) AS key_user,
        $pick($dialog_key(c.dialog), $user_key(c.dialog)) AS join_key
    FROM $input2 AS c
);

-- LEFT JOIN: пары без третьего ответа остаются со всем, что в них уже есть,
-- и видны по NULL в model_3, а не пропадают молча.
$joined = (
    SELECT
        a.* WITHOUT if exists a._other, a.key_dialog, a.key_user,

        b.vendor            AS model_3,
        b.answer            AS answer_3,
        b.row_id            AS row_id_3,
        b.account           AS account_3,
        b.s3_page_source    AS s3_page_source_3,
        b.answer_time       AS answer_time_3
    FROM (SELECT * FROM $pairs WHERE join_key != '') AS a
    LEFT JOIN (SELECT * FROM $third WHERE join_key != '') AS b ON a.join_key == b.join_key
);

INSERT INTO $output1 WITH TRUNCATE
SELECT j.* WITHOUT if exists j.join_key
FROM $joined AS j;

$pair_rows = (SELECT COUNT(*) FROM $pairs);
$third_rows = (SELECT COUNT(*) FROM $third);

$shared_dialog = (
    SELECT COUNT(*)
    FROM (SELECT DISTINCT key_dialog FROM $pairs WHERE key_dialog != '') AS l
    INNER JOIN (SELECT DISTINCT key_dialog FROM $third WHERE key_dialog != '') AS r
    USING (key_dialog)
);

$shared_user = (
    SELECT COUNT(*)
    FROM (SELECT DISTINCT key_user FROM $pairs WHERE key_user != '') AS l
    INNER JOIN (SELECT DISTINCT key_user FROM $third WHERE key_user != '') AS r
    USING (key_user)
);

INSERT INTO $output2 WITH TRUNCATE
SELECT
    $key_mode                           AS key_mode,
    $pair_rows                          AS pair_rows,
    $third_rows                         AS third_rows,
    COUNT(*)                            AS joined_rows,
    COUNT_IF(model_3 IS NOT NULL)       AS matched_rows,
    COUNT(DISTINCT join_key)            AS joined_keys,
    $shared_dialog                      AS shared_keys_dialog,
    $shared_user                        AS shared_keys_user
FROM $joined;
