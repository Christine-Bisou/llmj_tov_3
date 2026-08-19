PRAGMA Yson.AutoConvert;
PRAGMA yson.DisableStrict;
PRAGMA SimpleColumns;
PRAGMA AnsiInForEmptyOrNullableItemsCollections;
PRAGMA yt.InferSchema = '1';

DECLARE $input1 AS String;
DECLARE $input2 AS String;
DECLARE $output1 AS String;
DECLARE $output2 AS String;

-- input1 — основная таблица, ключ лежит колонкой instruct_id.
-- input2 — таблица с флагами, ключ спрятан в input_meta.instruct_id.
-- output1 — input1 плюс колонки флагов из input2.
-- output2 — проверка склейки: ключи без пары и ключи с дублями (в норме таблица пустая).

-- Ключ из input_meta. AutoConvert приводит и число, и строку; COALESCE — страховка.
$meta_iid = ($m) -> {
    RETURN COALESCE(
        Yson::LookupString($m, 'instruct_id'),
        CAST(Yson::LookupInt64($m, 'instruct_id') AS String)
    );
};

$left = (
    SELECT
        CAST(t.instruct_id AS String) AS join_id,
        t.*
    FROM $input1 AS t
);

$right = (
    SELECT
        -- если input_meta хранится строкой с JSON, замени на:
        -- $meta_iid(Yson::ParseJson(CAST(t.input_meta AS Utf8)))
        $meta_iid(t.input_meta)         AS join_id,

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

        -- если m_* лежат не отдельными колонками, а внутри tov_markers, то вместо
        -- пяти строк выше:
        -- Yson::ConvertToBool(Yson::Lookup(t.tov_markers, 'm_effekt_dosye')) ?? false AS m_effekt_dosye,
        -- ... и так по каждому маркеру
    FROM $input2 AS t
);

-- ========================= ВЫХОД 1: склейка =========================
-- LEFT JOIN: строки input1 не теряются, у непосматчившихся флаги будут NULL.
-- Нужны только сматчившиеся — поменяй на INNER JOIN.
INSERT INTO $output1 WITH TRUNCATE
SELECT
    -- добавленные колонки идут ДО a.*: WITHOUT обязан быть последним в списке
    b.tov_cnt                       AS tov_cnt,
    b.tov_flag                      AS tov_flag,
    b.tov_group                     AS tov_group,
    b.tov_markers                   AS tov_markers,
    b.verdict                       AS verdict,

    b.m_effekt_dosye                AS m_effekt_dosye,
    b.m_mashinnaya_formulirovka     AS m_mashinnaya_formulirovka,
    b.m_navyazchivoe_povtorenie     AS m_navyazchivoe_povtorenie,
    b.m_sensitivnaya_tyazhelovesno  AS m_sensitivnaya_tyazhelovesno,
    b.m_zapreshchennye_dannye       AS m_zapreshchennye_dannye,

    a.*
    WITHOUT IF EXISTS
        a.join_id,
        -- одноимённые колонки из input1 выкидываем, иначе конфликт имён
        a.tov_cnt, a.tov_flag, a.tov_group, a.tov_markers, a.verdict,
        a.m_effekt_dosye, a.m_mashinnaya_formulirovka, a.m_navyazchivoe_povtorenie,
        a.m_sensitivnaya_tyazhelovesno, a.m_zapreshchennye_dannye
FROM $left AS a
LEFT JOIN $right AS b
ON a.join_id = b.join_id;

-- ========================= ВЫХОД 2: контроль склейки =========================
$check = (
    SELECT
        a.join_id            AS join_id,
        COUNT(b.join_id)     AS matches
    FROM $left AS a
    LEFT JOIN $right AS b
    ON a.join_id = b.join_id
    GROUP BY a.join_id
);

INSERT INTO $output2 WITH TRUNCATE
SELECT
    join_id  AS instruct_id,
    matches  AS matches,
    IF(matches = 0, 'нет пары во второй таблице', 'дубли во второй таблице') AS problem
FROM $check
WHERE matches != 1
ORDER BY matches DESC, instruct_id
LIMIT 100000;
