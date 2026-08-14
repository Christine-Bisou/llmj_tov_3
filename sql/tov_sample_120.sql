PRAGMA yt.InferSchema = "100";
PRAGMA AnsiInForEmptyOrNullableItemsCollections;
PRAGMA AnsiOptionalAs;
PRAGMA yt.UseNativeYtTypes;
PRAGMA yson.DisableStrict;
PRAGMA Yson.AutoConvert;
PRAGMA SimpleColumns;

DECLARE $input1 AS String;
DECLARE $output1 AS String;   -- norm: 60 (30 с одним маркером + 30 с несколькими)
DECLARE $output2 AS String;   -- bad:  60 (30 с одним маркером + 30 с несколькими)
DECLARE $output3 AS String;   -- сводка: сколько было в пуле и сколько реально взяли

-- ============================================================================
-- Выборка 120 примеров: 60 norm + 60 bad, внутри каждого — половина с ровно
-- одним ToV-маркером «да», половина с двумя и более.
--
-- Колонка с вердиктом ниже названа verdict — если в таблице она называется
-- иначе, поправь $verdict_col (единственное место).
-- ============================================================================

$size = CAST(30 AS Uint64);   -- на каждую из 4 корзин: norm/1, norm/2+, bad/1, bad/2+

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

-- ========================= 1. Флаги маркеров =========================
$flags = (
    SELECT
        $re_repetition($txt(gpt_result)) AS f_repetition,
        $re_machine($txt(gpt_result))    AS f_machine,
        $re_heavy($txt(gpt_result))      AS f_heavy,
        $re_dossier($txt(gpt_result))    AS f_dossier,
        $re_forbidden($txt(gpt_result))  AS f_forbidden,
        -- воспроизводимый псевдослучайный ключ: одна и та же строка всегда
        -- получает один и тот же порядок, повторный запуск даст ту же выборку
        Digest::CityHash($txt(gpt_result) || '#' || CAST(TableRecordIndex() AS String)) AS shuffle,
        t.*
    FROM $input1 AS t
);

-- ========================= 2. Пул кандидатов =========================
-- Берём только строки, где сработал хотя бы один маркер и вердикт norm/bad.
$pool = (
    SELECT
        $verdict_col(verdict)                                                                AS verdict_norm,
        $cnt(f_repetition, f_machine, f_heavy, f_dossier, f_forbidden)                       AS tov_cnt,
        $names(f_repetition, f_machine, f_heavy, f_dossier, f_forbidden)                     AS tov_markers,
        IF($cnt(f_repetition, f_machine, f_heavy, f_dossier, f_forbidden) = 1, '1', '2+')    AS tov_group,
        $verdict_col(verdict)
            || '_'
            || IF($cnt(f_repetition, f_machine, f_heavy, f_dossier, f_forbidden) = 1, '1', '2+') AS bucket,
        IF(f_repetition, 'да', 'нет')                                                        AS m_navyazchivoe_povtorenie,
        IF(f_machine,    'да', 'нет')                                                        AS m_mashinnaya_formulirovka,
        IF(f_heavy,      'да', 'нет')                                                        AS m_sensitivnaya_tyazhelovesno,
        IF(f_dossier,    'да', 'нет')                                                        AS m_effekt_dosye,
        IF(f_forbidden,  'да', 'нет')                                                        AS m_zapreshchennye_dannye,
        t.*,
        WITHOUT
            t.f_repetition, t.f_machine, t.f_heavy, t.f_dossier, t.f_forbidden
    FROM $flags AS t
    WHERE $cnt(f_repetition, f_machine, f_heavy, f_dossier, f_forbidden) >= 1
      AND $verdict_col(verdict) IN ('norm', 'bad')
);

-- ========================= 3. Квоты по корзинам =========================
-- ROW_NUMBER внутри каждой из 4 корзин, дальше отсекаем по $size.
$ranked = (
    SELECT
        ROW_NUMBER() OVER w AS rn,
        t.*
    FROM $pool AS t
    WINDOW w AS (PARTITION BY bucket ORDER BY shuffle)
);

$sample = (
    SELECT t.*
    FROM $ranked AS t
    WHERE t.rn <= $size
);

-- ========================= ВЫХОД 1: norm =========================
INSERT INTO $output1 WITH TRUNCATE
SELECT
    t.*,
    WITHOUT t.shuffle
FROM $sample AS t
WHERE t.verdict_norm == 'norm'
ORDER BY tov_group, rn;

-- ========================= ВЫХОД 2: bad =========================
INSERT INTO $output2 WITH TRUNCATE
SELECT
    t.*,
    WITHOUT t.shuffle
FROM $sample AS t
WHERE t.verdict_norm == 'bad'
ORDER BY tov_group, rn;

-- ========================= ВЫХОД 3: контроль квот =========================
-- Если в какой-то корзине available < 30, до 120 строк не хватит —
-- видно сразу здесь, гадать по размеру таблиц не нужно.
INSERT INTO $output3 WITH TRUNCATE
SELECT
    p.bucket           AS bucket,
    p.verdict_norm     AS verdict_norm,
    p.tov_group        AS tov_group,
    COUNT(*)           AS available,
    MIN_OF(COUNT(*), $size) AS taken,
    AVG(p.tov_cnt)     AS avg_tov_cnt,
    MAX(p.tov_cnt)     AS max_tov_cnt
FROM $pool AS p
GROUP BY p.bucket, p.verdict_norm, p.tov_group
ORDER BY bucket;
