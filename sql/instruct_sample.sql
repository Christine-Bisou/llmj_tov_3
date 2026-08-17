PRAGMA yt.InferSchema = "100";
PRAGMA AnsiInForEmptyOrNullableItemsCollections;
PRAGMA AnsiOptionalAs;
PRAGMA yt.UseNativeYtTypes;
PRAGMA yson.DisableStrict;
PRAGMA Yson.AutoConvert;
PRAGMA SimpleColumns;

DECLARE $input1 AS String;    -- таблица с ризонингом судьи (gpt_result + verdict)
DECLARE $input2 AS String;    -- изначальная таблица, откуда берём good
DECLARE $output1 AS String;   -- итог: 180 строк (60 norm + 60 bad + 60 good)
DECLARE $output2 AS String;   -- instruct_id + answer + answer_source = 'model_1'
DECLARE $output3 AS String;   -- то же самое, но answer_source = 'model_2'

-- ============================================================================
-- 60 norm + 60 bad + 60 good, поровну.
--
--   norm / bad — из $input1, только там, где сработал хотя бы один ToV-маркер:
--                внутри каждого вердикта 30 строк с ровно одним маркером
--                и 30 строк с двумя и более.
--   good       — из $input2, без разбора маркеров: tov_cnt = 0, tov_markers = ''
--                (описания проблемы нет), все m_* = 'нет'.
--
-- instruct_id — String, сквозной по всем 180 строкам ('001'..'180'), одинаковый
-- в output1, output2 и output3, так что таблицы джойнятся по нему.
-- Если во входных таблицах уже есть своя колонка instruct_id, она затирается
-- этой (WITHOUT IF EXISTS ниже) — нужен исходный, сохрани его под другим именем.
--
-- output2 и output3 — одни и те же 180 пар instruct_id + answer, различаются
-- только меткой answer_source ('model_1' и 'model_2'): один и тот же ответ
-- заходит в разметку с обеих сторон пары.
--
-- Колонка с вердиктом ниже названа verdict. Если в таблицах она называется
-- иначе — поменять в вызовах $verdict_col(verdict).
-- ============================================================================

$size      = CAST(30 AS Uint64);   -- на каждую из 4 корзин: norm/1, norm/2+, bad/1, bad/2+
$size_good = CAST(60 AS Uint64);   -- good берём одной корзиной

-- Маркеры ToV в ризонинге gpt_result. Регулярки терпимы к markdown и регистру,
-- хвост (?:[^а-яёА-ЯЁ]|$) не даёт «да» склеиться со словом («данные», «даже»).
$re_repetition = Re2::Grep(@@(?i)Навязчивое повторение[\s\*_]{0,6}:[\s\*_]{0,6}да(?:[^а-яёА-ЯЁ]|$)@@);
$re_machine    = Re2::Grep(@@(?i)Машинная формулировка[\s\*_]{0,6}:[\s\*_]{0,6}да(?:[^а-яёА-ЯЁ]|$)@@);
$re_heavy      = Re2::Grep(@@(?i)Сенситивная память[^:\n]{0,60}:[\s\*_]{0,6}да(?:[^а-яёА-ЯЁ]|$)@@);
$re_dossier    = Re2::Grep(@@(?i)Эффект досье[\s\*_]{0,6}:[\s\*_]{0,6}да(?:[^а-яёА-ЯЁ]|$)@@);
$re_forbidden  = Re2::Grep(@@(?i)Запрещ[её]нные данные[\s\*_]{0,6}:[\s\*_]{0,6}да(?:[^а-яёА-ЯЁ]|$)@@);

$txt = ($s) -> { RETURN CAST($s AS String) ?? ''; };

-- вердикт к нижнему регистру и без пробелов по краям
$verdict_col = ($v) -> { RETURN String::AsciiToLower(String::Strip($txt($v))); };

-- порядковый номер -> String с ведущими нулями: 7 -> '007', 42 -> '042'
$pad3 = ($n) -> {
    RETURN IF($n < 10ul, '00', IF($n < 100ul, '0', '')) || CAST($n AS String);
};

$cnt = ($a, $b, $c, $d, $e) -> {
    RETURN IF($a, 1, 0) + IF($b, 1, 0) + IF($c, 1, 0) + IF($d, 1, 0) + IF($e, 1, 0);
};

$names = ($a, $b, $c, $d, $e) -> {
    RETURN ListConcat(
        ListNotNull(AsList(
            IF($a, 'Навязчивое повторение'),
            IF($b, 'Машинная формулировка'),
            IF($c, 'Сенситивная память по теме, но тяжеловесно'),
            IF($d, 'Эффект досье'),
            IF($e, 'Запрещённые данные')
        )),
        ', '
    ) ?? '';
};

-- ========================= 1. Флаги маркеров ($input1) =========================
$flags = (
    SELECT
        $re_repetition($txt(gpt_result)) AS f_repetition,
        $re_machine($txt(gpt_result))    AS f_machine,
        $re_heavy($txt(gpt_result))      AS f_heavy,
        $re_dossier($txt(gpt_result))    AS f_dossier,
        $re_forbidden($txt(gpt_result))  AS f_forbidden,
        -- воспроизводимый псевдослучайный ключ: повторный прогон даст ту же выборку
        Digest::CityHash($txt(gpt_result) || '#' || CAST(TableRecordIndex() AS String)) AS shuffle,
        t.*,
        -- если такие колонки уже есть во входе, свои считаем заново, чужие выкидываем
        WITHOUT IF EXISTS
            t.shuffle,
            t.f_repetition, t.f_machine, t.f_heavy, t.f_dossier, t.f_forbidden
    FROM $input1 AS t
);

-- ========================= 2. Пул norm/bad =========================
-- Только строки, где сработал хотя бы один маркер и вердикт norm или bad.
$pool = (
    SELECT
        $verdict_col(verdict)                                                                AS verdict_norm,
        $cnt(f_repetition, f_machine, f_heavy, f_dossier, f_forbidden)                       AS tov_cnt,
        $names(f_repetition, f_machine, f_heavy, f_dossier, f_forbidden)                     AS tov_markers,
        IF($cnt(f_repetition, f_machine, f_heavy, f_dossier, f_forbidden) = 1, '1', '2+')    AS tov_group,
        $verdict_col(verdict)
            || '_'
            || IF($cnt(f_repetition, f_machine, f_heavy, f_dossier, f_forbidden) = 1, '1', '2+') AS bucket,
        'да'                                                                                 AS tov_flag,
        IF(f_repetition, 'да', 'нет')                                                        AS m_navyazchivoe_povtorenie,
        IF(f_machine,    'да', 'нет')                                                        AS m_mashinnaya_formulirovka,
        IF(f_heavy,      'да', 'нет')                                                        AS m_sensitivnaya_tyazhelovesno,
        IF(f_dossier,    'да', 'нет')                                                        AS m_effekt_dosye,
        IF(f_forbidden,  'да', 'нет')                                                        AS m_zapreshchennye_dannye,
        t.*,
        WITHOUT IF EXISTS
            t.f_repetition, t.f_machine, t.f_heavy, t.f_dossier, t.f_forbidden,
            t.verdict_norm, t.tov_cnt, t.tov_markers, t.tov_group, t.bucket, t.tov_flag,
            t.m_navyazchivoe_povtorenie, t.m_mashinnaya_formulirovka,
            t.m_sensitivnaya_tyazhelovesno, t.m_effekt_dosye, t.m_zapreshchennye_dannye
    FROM $flags AS t
    WHERE $cnt(f_repetition, f_machine, f_heavy, f_dossier, f_forbidden) >= 1
      AND $verdict_col(verdict) IN ('norm', 'bad')
);

-- ROW_NUMBER внутри каждой из 4 корзин, дальше отсекаем по $size.
-- rn — служебный счётчик отсечения, в выход не идёт.
$sample_nb = (
    SELECT t.*
    FROM (
        SELECT
            ROW_NUMBER() OVER w AS rn,
            t.*,
            WITHOUT IF EXISTS t.rn
        FROM $pool AS t
        WINDOW w AS (PARTITION BY bucket ORDER BY shuffle)
    ) AS t
    WHERE t.rn <= $size
);

-- ========================= 3. Пул good ($input2) =========================
-- Маркеры не ищем: у good их по определению нет.
$pool_good = (
    SELECT
        Digest::CityHash('good#' || CAST(TableRecordIndex() AS String)) AS shuffle,
        t.*,
        WITHOUT IF EXISTS t.shuffle
    FROM $input2 AS t
    WHERE $verdict_col(verdict) == 'good'
);

$sample_good = (
    SELECT
        'good'         AS verdict_norm,
        CAST(0 AS Int32) AS tov_cnt,
        ''             AS tov_markers,   -- проблем не описано
        '0'            AS tov_group,
        'good_0'       AS bucket,
        'нет'          AS tov_flag,
        'нет'          AS m_navyazchivoe_povtorenie,
        'нет'          AS m_mashinnaya_formulirovka,
        'нет'          AS m_sensitivnaya_tyazhelovesno,
        'нет'          AS m_effekt_dosye,
        'нет'          AS m_zapreshchennye_dannye,
        t.*,
        -- в изначальной таблице такие колонки уже могут быть — свои ставим сами
        WITHOUT IF EXISTS
            t.verdict_norm, t.tov_cnt, t.tov_markers, t.tov_group, t.bucket, t.tov_flag,
            t.m_navyazchivoe_povtorenie, t.m_mashinnaya_formulirovka,
            t.m_sensitivnaya_tyazhelovesno, t.m_effekt_dosye, t.m_zapreshchennye_dannye
    FROM (
        SELECT
            ROW_NUMBER() OVER w AS rn,
            t.*,
            WITHOUT IF EXISTS t.rn
        FROM $pool_good AS t
        WINDOW w AS (ORDER BY shuffle)
    ) AS t
    WHERE t.rn <= $size_good
);

-- ========================= 4. Итог + сквозной instruct_id =========================
-- UNION ALL склеивает по именам колонок: то, чего нет в $input2 (gpt_result и
-- прочие поля судьи), у good-строк будет NULL, и наоборот.
$final = (
    SELECT t.* FROM $sample_nb   AS t
    UNION ALL
    SELECT t.* FROM $sample_good AS t
);

-- Один ROW_NUMBER на все 180 строк: id уникален и одинаков во всех трёх выходах.
$final_id = (
    SELECT
        $pad3(ROW_NUMBER() OVER w) AS instruct_id,
        t.*,
        WITHOUT IF EXISTS t.instruct_id
    FROM $final AS t
    WINDOW w AS (ORDER BY bucket, shuffle)
);

-- ========================= ВЫХОД 1: 180 строк =========================
INSERT INTO $output1 WITH TRUNCATE
SELECT
    t.*,
    WITHOUT t.shuffle, t.rn
FROM $final_id AS t
ORDER BY instruct_id;

-- ========================= ВЫХОД 2: answer как model_1 =========================
INSERT INTO $output2 WITH TRUNCATE
SELECT
    t.instruct_id AS instruct_id,
    t.answer      AS answer,
    'model_1'     AS answer_source
FROM $final_id AS t
ORDER BY instruct_id;

-- ========================= ВЫХОД 3: тот же answer как model_2 =========================
INSERT INTO $output3 WITH TRUNCATE
SELECT
    t.instruct_id AS instruct_id,
    t.answer      AS answer,
    'model_2'     AS answer_source
FROM $final_id AS t
ORDER BY instruct_id;
