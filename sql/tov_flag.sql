PRAGMA yt.InferSchema;
PRAGMA Yson.AutoConvert;
PRAGMA yson.DisableStrict;
PRAGMA SimpleColumns;
PRAGMA AnsiInForEmptyOrNullableItemsCollections;

DECLARE $input1 AS String;
DECLARE $output1 AS String;

-- В gpt_result лежит ризонинг судьи. Внутри есть строки вида
--   «Навязчивое повторение: нет» / «Машинная формулировка: да».
-- Нужен флаг: если ХОТЯ БЫ ОДИН из ToV-маркеров помечен «да» → tov_flag = 'да'.
--
-- Регулярки терпимы к разметке и мусору:
--   «- **Навязчивое повторение:** да», «Навязчивое повторение : ДА»,
--   «Эффект досье: да — ассистент вываливает всё сразу».
-- Хвост (?:[^а-яёА-ЯЁ]|$) нужен, чтобы «да» не склеилось со словом
-- («данные», «дальше», «даже»): после «да» обязана идти не-кириллица либо конец текста.

$re_repetition = Re2::Grep(@@(?i)Навязчивое повторение[\s\*_]{0,6}:[\s\*_]{0,6}да(?:[^а-яёА-ЯЁ]|$)@@);
$re_machine    = Re2::Grep(@@(?i)Машинная формулировка[\s\*_]{0,6}:[\s\*_]{0,6}да(?:[^а-яёА-ЯЁ]|$)@@);
$re_heavy      = Re2::Grep(@@(?i)Сенситивная память[^:\n]{0,60}:[\s\*_]{0,6}да(?:[^а-яёА-ЯЁ]|$)@@);
$re_dossier    = Re2::Grep(@@(?i)Эффект досье[\s\*_]{0,6}:[\s\*_]{0,6}да(?:[^а-яёА-ЯЁ]|$)@@);
$re_forbidden  = Re2::Grep(@@(?i)Запрещ[её]нные данные[\s\*_]{0,6}:[\s\*_]{0,6}да(?:[^а-яёА-ЯЁ]|$)@@);

$yn = ($b) -> { RETURN IF($b, 'да', 'нет'); };

$flags = (
    SELECT
        $re_repetition(CAST(gpt_result AS String) ?? '') AS f_repetition,
        $re_machine(CAST(gpt_result AS String) ?? '')    AS f_machine,
        $re_heavy(CAST(gpt_result AS String) ?? '')      AS f_heavy,
        $re_dossier(CAST(gpt_result AS String) ?? '')    AS f_dossier,
        $re_forbidden(CAST(gpt_result AS String) ?? '')  AS f_forbidden,
        t.*
    FROM $input1 AS t
);

INSERT INTO $output1 WITH TRUNCATE
SELECT
    -- дополнительные колонки идут ДО t.*: WITHOUT обязан быть последним в списке
    $yn(t.f_repetition) AS m_navyazchivoe_povtorenie,
    $yn(t.f_machine)    AS m_mashinnaya_formulirovka,
    $yn(t.f_heavy)      AS m_sensitivnaya_tyazhelovesno,
    $yn(t.f_dossier)    AS m_effekt_dosye,
    $yn(t.f_forbidden)  AS m_zapreshchennye_dannye,
    -- какие именно маркеры сработали, через запятую
    ListConcat(
        ListNotNull(AsList(
            IF(t.f_repetition, 'Навязчивое повторение'),
            IF(t.f_machine,    'Машинная формулировка'),
            IF(t.f_heavy,      'Сенситивная память по теме, но тяжеловесно'),
            IF(t.f_dossier,    'Эффект досье'),
            IF(t.f_forbidden,  'Запрещённые данные')
        )),
        ', '
    ) ?? '' AS tov_markers,
    IF(t.f_repetition, 1, 0) + IF(t.f_machine, 1, 0) + IF(t.f_heavy, 1, 0)
        + IF(t.f_dossier, 1, 0) + IF(t.f_forbidden, 1, 0) AS tov_cnt,
    -- хотя бы одна подстрока найдена → 'да'
    $yn(t.f_repetition OR t.f_machine OR t.f_heavy OR t.f_dossier OR t.f_forbidden) AS tov_flag,
    t.*,
    WITHOUT
        t.f_repetition, t.f_machine, t.f_heavy, t.f_dossier, t.f_forbidden
FROM $flags AS t
-- убери WHERE, если нужны все строки, а не только сработавшие
WHERE t.f_repetition OR t.f_machine OR t.f_heavy OR t.f_dossier OR t.f_forbidden;

-- ========================= Упрощённый вариант =========================
-- Если разметка в gpt_result всегда ровно «Маркер: да», без markdown и без
-- разнобоя в регистре, хватит обычного поиска подстроки — без Re2:
--
-- $has_tov = ($s) -> {
--     $t = CAST($s AS String) ?? '';
--     RETURN String::Contains($t, 'Навязчивое повторение: да')
--         OR String::Contains($t, 'Машинная формулировка: да')
--         OR String::Contains($t, 'Сенситивная память по теме, но тяжеловесно: да')
--         OR String::Contains($t, 'Эффект досье: да')
--         OR String::Contains($t, 'Запрещённые данные: да');
-- };
--
-- INSERT INTO $output1 WITH TRUNCATE
-- SELECT IF($has_tov(gpt_result), 'да', 'нет') AS tov_flag, t.*
-- FROM $input1 AS t
-- WHERE $has_tov(gpt_result);
