PRAGMA Yson.AutoConvert;
PRAGMA yson.DisableStrict;
PRAGMA SimpleColumns;
PRAGMA AnsiInForEmptyOrNullableItemsCollections;
PRAGMA yt.InferSchema = '1';

DECLARE $input1 AS String;
DECLARE $input2 AS String;
DECLARE $output1 AS String;

-- input1 — таблица с флагами, ключ лежит колонкой instruct_id.
-- input2 — основная таблица, ключ спрятан в input_meta.instruct_id.
-- output1 — все колонки input2 плюс приклеенные флаги из input1.

-- Ключ из input_meta. AutoConvert приводит и число, и строку; COALESCE — страховка.
$meta_iid = ($m) -> {
    RETURN COALESCE(
        Yson::LookupString($m, 'instruct_id'),
        CAST(Yson::LookupInt64($m, 'instruct_id') AS String)
    );
};

-- Флаги: только ключ и нужные колонки, ничего лишнего в джоин не тащим.
$flags = (
    SELECT
        CAST(t.instruct_id AS String)   AS join_id,

        t.tov_cnt                       AS tov_cnt,
        t.tov_flag                      AS tov_flag,
        t.tov_group                     AS tov_group,
        t.tov_markers                   AS tov_markers,
        t.verdict                       AS verdict,

        t.m_effekt_dosye                AS m_effekt_dosye,
        t.m_mashinnaya_formulirovka     AS m_mashinnaya_formulirovka,
        t.m_navyazchivoe_povtorenie     AS m_navyazchivoe_povtorenie,
        t.m_sensitivnaya_tyazhelovesno  AS m_sensitivnaya_tyazhelovesno,
        t.m_zapreshchennye_dannye       AS m_zapreshchennye_dannye
    FROM $input1 AS t
);

$base = (
    SELECT
        -- если input_meta хранится строкой с JSON, замени на:
        -- $meta_iid(Yson::ParseJson(CAST(t.input_meta AS Utf8)))
        $meta_iid(t.input_meta) AS join_id,
        t.*
    FROM $input2 AS t
);

-- LEFT JOIN: строки input2 не теряются, у непосматчившихся флаги будут NULL.
-- Нужны только сматчившиеся — поменяй на INNER JOIN.
INSERT INTO $output1 WITH TRUNCATE
SELECT
    -- добавленные колонки идут ДО b.*: WITHOUT обязан быть последним в списке
    f.tov_cnt                       AS tov_cnt,
    f.tov_flag                      AS tov_flag,
    f.tov_group                     AS tov_group,
    f.tov_markers                   AS tov_markers,
    f.verdict                       AS verdict,

    f.m_effekt_dosye                AS m_effekt_dosye,
    f.m_mashinnaya_formulirovka     AS m_mashinnaya_formulirovka,
    f.m_navyazchivoe_povtorenie     AS m_navyazchivoe_povtorenie,
    f.m_sensitivnaya_tyazhelovesno  AS m_sensitivnaya_tyazhelovesno,
    f.m_zapreshchennye_dannye       AS m_zapreshchennye_dannye,

    b.*
    WITHOUT IF EXISTS
        b.join_id,
        -- одноимённые колонки из input2 выкидываем, иначе конфликт имён
        b.tov_cnt, b.tov_flag, b.tov_group, b.tov_markers, b.verdict,
        b.m_effekt_dosye, b.m_mashinnaya_formulirovka, b.m_navyazchivoe_povtorenie,
        b.m_sensitivnaya_tyazhelovesno, b.m_zapreshchennye_dannye
FROM $base AS b
LEFT JOIN $flags AS f
ON b.join_id = f.join_id;
